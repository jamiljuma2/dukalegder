import { useEffect, useRef, useState } from 'react'
import { ImagePlus, Trash2, Upload } from 'lucide-react'

export function ProductImagePlaceholder({ label = 'No product image' }) {
  return <span className="product-image-placeholder" aria-label={label}><ImagePlus aria-hidden="true"/><span>{label}</span></span>
}

export function ProductImageView({ src, alt, label = 'No product image' }) {
  const [failed, setFailed] = useState(false)
  useEffect(() => setFailed(false), [src])
  return src && !failed ? <img src={src} alt={alt} loading="lazy" decoding="async" sizes="(max-width: 700px) 50vw, (max-width: 1000px) 33vw, 220px" onError={() => setFailed(true)}/> : <ProductImagePlaceholder label={label}/>
}

export function ProductThumbnail({ src, alt = '', className = '' }) {
  const [failed, setFailed] = useState(false)
  useEffect(() => setFailed(false), [src])
  return <span className={`product-thumbnail ${className}`}>
    {src && !failed ? <img src={src} alt={alt} loading="lazy" decoding="async" sizes="56px" onError={() => setFailed(true)}/> : <ImagePlus aria-hidden="true"/>}
  </span>
}

export default function ProductImagePicker({ src, onSelect, onRemove }) {
  const galleryInput = useRef(null)
  const [previewFailed, setPreviewFailed] = useState(false)

  useEffect(() => setPreviewFailed(false), [src])

  function handleFile(event) {
    const file = event.target.files?.[0]
    event.target.value = ''
    if (file) onSelect(file)
  }

  return <div className="product-image-field">
    <span className="product-image-label">Product photo <span className="optional">Optional · JPEG, PNG or WebP · up to 2 MB</span></span>
    <div className={`product-image-preview ${src ? 'has-image' : ''}`}>
      {src && !previewFailed ? <img src={src} alt="Product image preview" onError={() => setPreviewFailed(true)}/> : <ProductImagePlaceholder label={src ? 'Image preview unavailable' : 'Add an optional product photo'}/>}
      {src && <button className="product-image-remove" type="button" onClick={onRemove} aria-label="Remove product image"><Trash2 size={16}/></button>}
    </div>
    <div className="product-image-actions">
      <button className="button secondary small" type="button" onClick={() => galleryInput.current?.click()}><Upload size={15}/>Upload Image</button>
      <input ref={galleryInput} className="product-image-input" type="file" accept="image/jpeg,image/png,image/webp" capture="environment" onChange={handleFile} aria-label="Take or select a product image"/>
    </div>
    <p className="product-image-help">Images are resized automatically before upload. You can replace or remove the photo before saving.</p>
  </div>
}
