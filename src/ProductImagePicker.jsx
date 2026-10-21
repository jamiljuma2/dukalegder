import { useEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { Camera, ImagePlus, Trash2, Upload, X } from 'lucide-react'

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

export default function ProductImagePicker({ src, onSelect, onRemove, onError }) {
  const galleryInput = useRef(null)
  const captureInput = useRef(null)
  const video = useRef(null)
  const streamRef = useRef(null)
  const [cameraOpen, setCameraOpen] = useState(false)
  const [cameraBusy, setCameraBusy] = useState(false)
  const [captureError, setCaptureError] = useState('')
  const [previewFailed, setPreviewFailed] = useState(false)

  useEffect(() => setPreviewFailed(false), [src])

  useEffect(() => {
    if (video.current && streamRef.current) video.current.srcObject = streamRef.current
  }, [cameraOpen])

  function stopCamera() {
    streamRef.current?.getTracks().forEach(track => track.stop())
    streamRef.current = null
    setCameraOpen(false)
    setCameraBusy(false)
    setCaptureError('')
  }

  useEffect(() => () => streamRef.current?.getTracks().forEach(track => track.stop()), [])

  async function takePhoto() {
    const mobile = window.matchMedia?.('(pointer: coarse)').matches || /android|iphone|ipad|ipod/i.test(navigator.userAgent)
    if (mobile) {
      captureInput.current?.click()
      return
    }
    if (!navigator.mediaDevices?.getUserMedia) {
      onError('A camera is not available here. Choose Upload Image to select a file.')
      galleryInput.current?.click()
      return
    }
    setCameraBusy(true)
    try {
      streamRef.current = await navigator.mediaDevices.getUserMedia({ video: { facingMode: { ideal: 'environment' } }, audio: false })
      setCameraBusy(false)
      setCameraOpen(true)
    } catch (error) {
      streamRef.current?.getTracks().forEach(track => track.stop())
      streamRef.current = null
      setCameraBusy(false)
      onError(error?.name === 'NotAllowedError' || error?.name === 'PermissionDeniedError'
        ? 'Camera access was denied. You can still choose Upload Image.'
        : 'Could not start the camera. You can still choose Upload Image.')
      galleryInput.current?.click()
    }
  }

  async function captureFrame() {
    const element = video.current
    if (!element?.videoWidth || !element?.videoHeight) {
      setCaptureError('The camera is still starting. Try again in a moment.')
      return
    }
    setCameraBusy(true)
    const scale = Math.min(1, 1200 / Math.max(element.videoWidth, element.videoHeight))
    const canvas = document.createElement('canvas')
    canvas.width = Math.round(element.videoWidth * scale)
    canvas.height = Math.round(element.videoHeight * scale)
    const context = canvas.getContext('2d')
    if (!context) {
      setCameraBusy(false)
      setCaptureError('Camera capture is unavailable. Choose Upload Image instead.')
      return
    }
    context.drawImage(element, 0, 0, canvas.width, canvas.height)
    canvas.toBlob(blob => {
      if (!blob) {
        setCameraBusy(false)
        setCaptureError('The photo could not be captured. Try again or upload an image.')
        return
      }
      const photo = new File([blob], `camera-${Date.now()}.jpg`, { type: blob.type || 'image/jpeg', lastModified: Date.now() })
      stopCamera()
      onSelect(photo)
    }, 'image/jpeg', 0.9)
  }

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
      <button className="button secondary small" type="button" onClick={takePhoto} disabled={cameraBusy}><Camera size={15}/>Take Photo</button>
      <button className="button secondary small" type="button" onClick={() => galleryInput.current?.click()}><Upload size={15}/>Upload Image</button>
      <input ref={galleryInput} className="product-image-input" type="file" accept="image/jpeg,image/png,image/webp" onChange={handleFile} aria-label="Upload product image"/>
      <input ref={captureInput} className="product-image-input" type="file" accept="image/*" capture="environment" onChange={handleFile} aria-label="Take a product photo"/>
    </div>
    <p className="product-image-help">Images are resized before upload. You can replace or remove the photo before saving.</p>
    {cameraOpen && createPortal(<div className="modal-backdrop camera-backdrop" role="presentation" onMouseDown={event => event.target === event.currentTarget && stopCamera()}>
      <section className="modal camera-modal" role="dialog" aria-modal="true" aria-labelledby="camera-title">
        <div className="modal-head"><h2 id="camera-title">Take a product photo</h2><button type="button" className="icon-button" onClick={stopCamera} aria-label="Close camera"><X size={18}/></button></div>
        <div className="camera-content"><video ref={video} autoPlay playsInline muted/><p role="status">{captureError}</p><div className="modal-actions"><button type="button" className="button secondary" onClick={stopCamera}>Cancel</button><button type="button" className="button primary" onClick={captureFrame} disabled={cameraBusy}><Camera size={16}/>{cameraBusy ? 'Capturing…' : 'Capture photo'}</button></div></div>
      </section>
    </div>, document.body)}
  </div>
}
