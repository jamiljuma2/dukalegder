-- Production-safe smoke test for the offline RPCs.
-- Each successful mutation is followed by a sentinel exception inside a
-- PL/pgSQL subtransaction, which rolls that test's writes back before moving on.
drop table if exists pg_temp.offline_rpc_test_results;
create temp table offline_rpc_test_results(test_name text, result text);

do $$
declare
  v_business uuid;
  v_user uuid;
  v_product uuid;
  v_updated_at timestamptz;
  v_values jsonb;
  v_expense_key uuid;
  v_customer_key uuid;
  v_stock_key uuid;
  v_sale_key uuid;
  v_product_key uuid;
  v_purchase_key uuid;
  v_purchase_edit_key uuid;
  v_repayment_key uuid;
  v_id_1 uuid;
  v_id_2 uuid;
  v_customer uuid;
  v_purchase uuid;
  v_owing numeric;
  v_delta integer;
  v_quantity integer;
  v_movement_count integer;
  v_path text;
  v_url text;
begin
  select bm.business_id, bm.user_id, p.id, p.updated_at, p.quantity,
         jsonb_build_object(
           'name', p.name, 'sku', p.sku, 'category', p.category,
           'buying_price', p.buying_price, 'selling_price', p.selling_price,
           'quantity', p.quantity, 'low_stock_threshold', p.low_stock_threshold,
           'description', p.description
         )
    into v_business, v_user, v_product, v_updated_at, v_quantity, v_values
    from public.business_members bm
    join public.products p on p.business_id = bm.business_id
   where bm.role = 'owner' and p.archived_at is null and p.quantity > 0
   order by p.updated_at desc
   limit 1;

  if v_business is null then
    raise exception 'Offline RPC smoke test needs an owner business with an active in-stock product';
  end if;

  perform set_config('request.jwt.claim.sub', v_user::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', v_user::text, 'role', 'authenticated'
  )::text, true);

  v_expense_key := gen_random_uuid();
  begin
    v_id_1 := public.record_expense(v_business, v_expense_key, 'Offline smoke test', 'Other', 1, current_date, 'cash', null);
    v_id_2 := public.record_expense(v_business, v_expense_key, 'Changed retry payload', 'Other', 2, current_date, 'cash', null);
    if v_id_1 is distinct from v_id_2 then raise exception 'Expense retry created a second row'; end if;
    raise exception 'OFFLINE_SMOKE_ROLLBACK';
  exception when others then
    if sqlerrm = 'OFFLINE_SMOKE_ROLLBACK' then
      insert into pg_temp.offline_rpc_test_results values ('expense idempotency', 'passed; rolled back');
    else raise; end if;
  end;

  v_customer_key := gen_random_uuid();
  begin
    v_id_1 := public.record_customer(v_business, v_customer_key, gen_random_uuid(), 'Offline smoke customer', null, null);
    v_id_2 := public.record_customer(v_business, v_customer_key, gen_random_uuid(), 'Changed retry payload', null, null);
    if v_id_1 is distinct from v_id_2 then raise exception 'Customer retry created a second row'; end if;
    raise exception 'OFFLINE_SMOKE_ROLLBACK';
  exception when others then
    if sqlerrm = 'OFFLINE_SMOKE_ROLLBACK' then
      insert into pg_temp.offline_rpc_test_results values ('customer idempotency', 'passed; rolled back');
    else raise; end if;
  end;

  v_stock_key := gen_random_uuid();
  begin
    perform public.adjust_stock_idempotent(v_business, v_product, v_stock_key, 1, 'Offline smoke test');
    perform public.adjust_stock_idempotent(v_business, v_product, v_stock_key, 1, 'Offline smoke retry');
    select count(*), coalesce(sum(quantity_delta), 0)
      into v_movement_count, v_delta
      from public.inventory_movements
     where business_id = v_business and request_key = v_stock_key;
    if v_movement_count <> 1 or v_delta <> 1 then raise exception 'Stock retry applied more than once'; end if;
    raise exception 'OFFLINE_SMOKE_ROLLBACK';
  exception when others then
    if sqlerrm = 'OFFLINE_SMOKE_ROLLBACK' then
      insert into pg_temp.offline_rpc_test_results values ('stock idempotency', 'passed; rolled back');
    else raise; end if;
  end;

  v_sale_key := gen_random_uuid();
  begin
    v_id_1 := public.create_sale(
      v_business, v_sale_key,
      jsonb_build_array(jsonb_build_object('product_id', v_product, 'quantity', 1)),
      'cash'::public.payment_method, null, null, 0
    );
    v_id_2 := public.create_sale(
      v_business, v_sale_key,
      jsonb_build_array(jsonb_build_object('product_id', v_product, 'quantity', 1)),
      'cash'::public.payment_method, null, null, 0
    );
    if v_id_1 is distinct from v_id_2 then raise exception 'Sale retry created a second transaction'; end if;
    raise exception 'OFFLINE_SMOKE_ROLLBACK';
  exception when others then
    if sqlerrm = 'OFFLINE_SMOKE_ROLLBACK' then
      insert into pg_temp.offline_rpc_test_results values ('sale idempotency and server stock validation', 'passed; rolled back');
    else raise; end if;
  end;

  begin
    perform public.create_sale(
      v_business, gen_random_uuid(),
      jsonb_build_array(jsonb_build_object('product_id', v_product, 'quantity', v_quantity + 1)),
      'cash'::public.payment_method, null, null, 0
    );
    raise exception 'Insufficient stock sale unexpectedly succeeded';
  exception when others then
    if sqlerrm like 'Insufficient stock for %' then
      insert into pg_temp.offline_rpc_test_results values ('insufficient stock conflict', 'passed; no writes');
    else raise; end if;
  end;

  v_product_key := gen_random_uuid();
  begin
    v_id_1 := public.offline_save_product(v_business, v_product, v_product_key, v_updated_at, v_values);
    v_id_2 := public.offline_save_product(v_business, v_product, v_product_key, v_updated_at, v_values);
    if v_id_1 is distinct from v_product or v_id_2 is distinct from v_product then raise exception 'Product retry returned a different product'; end if;
    begin
      perform public.offline_save_product(v_business, v_product, gen_random_uuid(), '1900-01-01'::timestamptz, v_values);
      raise exception 'Stale product edit unexpectedly succeeded';
    exception when others then
      if sqlerrm not like 'Product changed on another device.%' then raise; end if;
    end;
    v_path := v_business::text || '/' || v_product::text || '/' || gen_random_uuid()::text || '.jpg';
    v_url := 'https://example.invalid/storage/v1/object/public/product-images/' || v_path;
    perform public.offline_link_product_image(v_business, v_product, v_product_key, v_path, v_url);
    raise exception 'OFFLINE_SMOKE_ROLLBACK';
  exception when others then
    if sqlerrm = 'OFFLINE_SMOKE_ROLLBACK' then
      insert into pg_temp.offline_rpc_test_results values ('product conflict version, idempotency, and image association', 'passed; rolled back');
    else raise; end if;
  end;

  v_purchase_key := gen_random_uuid();
  v_purchase_edit_key := gen_random_uuid();
  begin
    v_purchase := public.save_supplier_purchase(
      v_business, null, v_purchase_key, null, 'OFFLINE-SMOKE-' || v_purchase_key::text,
      current_date, 'Offline smoke test',
      jsonb_build_array(jsonb_build_object('product_id', v_product, 'quantity', 1, 'unit_cost', 1))
    );
    select updated_at into v_updated_at from public.supplier_purchases where id = v_purchase;
    v_id_1 := public.offline_edit_supplier_purchase(
      v_business, v_purchase, v_purchase_edit_key, v_updated_at, null,
      'OFFLINE-SMOKE-' || v_purchase_key::text, current_date, 'Offline smoke retry',
      jsonb_build_array(jsonb_build_object('product_id', v_product, 'quantity', 1, 'unit_cost', 1))
    );
    v_id_2 := public.offline_edit_supplier_purchase(
      v_business, v_purchase, v_purchase_edit_key, v_updated_at, null,
      'Changed retry payload', current_date, 'Changed retry payload',
      jsonb_build_array(jsonb_build_object('product_id', v_product, 'quantity', 2, 'unit_cost', 2))
    );
    if v_id_1 is distinct from v_purchase or v_id_2 is distinct from v_purchase then raise exception 'Purchase retry returned a different purchase'; end if;
    begin
      perform public.offline_edit_supplier_purchase(
        v_business, v_purchase, gen_random_uuid(), '1900-01-01'::timestamptz, null,
        'OFFLINE-SMOKE-' || v_purchase_key::text, current_date, 'Stale purchase edit',
        jsonb_build_array(jsonb_build_object('product_id', v_product, 'quantity', 1, 'unit_cost', 1))
      );
      raise exception 'Stale purchase edit unexpectedly succeeded';
    exception when others then
      if sqlerrm not like 'Purchase draft changed on another device.%' then raise; end if;
    end;
    raise exception 'OFFLINE_SMOKE_ROLLBACK';
  exception when others then
    if sqlerrm = 'OFFLINE_SMOKE_ROLLBACK' then
      insert into pg_temp.offline_rpc_test_results values ('purchase draft creation, conflict version, and retry idempotency', 'passed; rolled back');
    else raise; end if;
  end;

  select b.customer_id, b.outstanding into v_customer, v_owing
    from public.customer_balances(v_business) b
   where b.outstanding > 0
   order by b.outstanding desc
   limit 1;
  if v_customer is null then
    insert into pg_temp.offline_rpc_test_results values ('repayment idempotency', 'skipped; no outstanding customer balance');
  else
    v_repayment_key := gen_random_uuid();
    begin
      v_id_1 := public.record_repayment(v_business, v_repayment_key, v_customer, least(v_owing, 1), 'cash', 'Offline smoke test');
      v_id_2 := public.record_repayment(v_business, v_repayment_key, v_customer, least(v_owing, 1), 'cash', 'Offline smoke retry');
      if v_id_1 is distinct from v_id_2 then raise exception 'Repayment retry created a second transaction'; end if;
      raise exception 'OFFLINE_SMOKE_ROLLBACK';
    exception when others then
      if sqlerrm = 'OFFLINE_SMOKE_ROLLBACK' then
        insert into pg_temp.offline_rpc_test_results values ('repayment idempotency', 'passed; rolled back');
      else raise; end if;
    end;
  end if;
end
$$;

select test_name, result from pg_temp.offline_rpc_test_results order by test_name;
