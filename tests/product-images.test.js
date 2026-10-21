import test from 'node:test'
import assert from 'node:assert/strict'
import {
  MAX_PRODUCT_IMAGE_BYTES,
  PRODUCT_IMAGE_SIZE,
  PRODUCT_IMAGE_TARGET_BYTES,
  prepareProductImage,
  productImagePath,
  validateProductImage,
} from '../src/lib/productImages.js'

const validJpeg = { name: 'stock-photo.jpg', type: 'image/jpeg', size: 1200 }

test('validates supported image formats and the 2 MB source limit', () => {
  assert.equal(validateProductImage(validJpeg), null)
  assert.equal(validateProductImage({ ...validJpeg, type: 'image/gif' }), 'Choose a JPEG, PNG, or WebP image.')
  assert.equal(validateProductImage({ ...validJpeg, size: MAX_PRODUCT_IMAGE_BYTES + 1 }), 'Images must be 2 MB or smaller.')
  assert.match(validateProductImage({ ...validJpeg, size: 0 }), /empty/)
})

test('resizes images to at most 600 px and prefers WebP', async () => {
  const previousBitmap = globalThis.createImageBitmap
  const previousDocument = globalThis.document
  let drawnSize
  globalThis.createImageBitmap = async () => ({ width: 1200, height: 600, close() {} })
  globalThis.document = { createElement: () => ({
    width: 0,
    height: 0,
    getContext: () => ({ drawImage: (_image, _x, _y, width, height) => { drawnSize = [width, height] }, save() {}, restore() {}, fillRect() {}, set globalCompositeOperation(_value) {}, set fillStyle(_value) {} }),
    toBlob: (callback, type) => callback(new Blob([new Uint8Array(80_000)], { type })),
  }) }
  try {
    const result = await prepareProductImage(validJpeg)
    assert.deepEqual(drawnSize, [PRODUCT_IMAGE_SIZE, 300])
    assert.equal(result.type, 'image/webp')
    assert.equal(result.size, 80_000)
    assert.equal(result.name, 'stock-photo.webp')
    assert.ok(result.size < PRODUCT_IMAGE_TARGET_BYTES)
  } finally {
    globalThis.createImageBitmap = previousBitmap
    globalThis.document = previousDocument
  }
})

test('reduces large JPEG output quality without reprocessing small output', async () => {
  const previousBitmap = globalThis.createImageBitmap
  const previousDocument = globalThis.document
  const qualityCalls = []
  globalThis.createImageBitmap = async () => ({ width: 600, height: 600, close() {} })
  globalThis.document = { createElement: () => ({
    width: 0,
    height: 0,
    getContext: () => ({ drawImage() {}, save() {}, restore() {}, fillRect() {}, set globalCompositeOperation(_value) {}, set fillStyle(_value) {} }),
    toBlob: (callback, type, quality) => {
      qualityCalls.push([type, quality])
      if (type === 'image/webp') callback(new Blob([new Uint8Array(10)], { type: 'image/png' }))
      else callback(new Blob([new Uint8Array(quality > 0.7 ? 280_000 : 160_000)], { type }))
    },
  }) }
  try {
    const result = await prepareProductImage(validJpeg)
    assert.equal(result.type, 'image/jpeg')
    assert.equal(result.size, 160_000)
    assert.deepEqual(qualityCalls, [['image/webp', 0.82], ['image/jpeg', 0.82], ['image/jpeg', 0.68]])
  } finally {
    globalThis.createImageBitmap = previousBitmap
    globalThis.document = previousDocument
  }
})

test('stores images under business and product folders with unique safe filenames', () => {
  const path = productImagePath('biz-1', 'product-2', { name: 'Fresh Apple.webp' })
  assert.match(path, /^biz-1\/product-2\/[0-9a-f-]+-fresh-apple\.webp$/)
})
