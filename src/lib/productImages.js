export const MAX_PRODUCT_IMAGE_BYTES = 2 * 1024 * 1024
export const PRODUCT_IMAGE_TYPES = new Set(['image/jpeg', 'image/png', 'image/webp'])
export const PRODUCT_IMAGE_SIZE = 600
export const PRODUCT_IMAGE_TARGET_BYTES = 200 * 1024

export function validateProductImage(file) {
  if (!file) return 'Choose an image first.'
  if (!PRODUCT_IMAGE_TYPES.has(file.type)) return 'Choose a JPEG, PNG, or WebP image.'
  if (file.size > MAX_PRODUCT_IMAGE_BYTES) return 'Images must be 2 MB or smaller.'
  if (!file.size) return 'This image file is empty. Choose another image.'
  return null
}

function canvasBlob(canvas, type, quality) {
  return new Promise((resolve, reject) => {
    canvas.toBlob(blob => blob ? resolve(blob) : reject(new Error('The image could not be prepared. Try another image.')), type, quality)
  })
}

async function loadImage(file) {
  if (typeof createImageBitmap === 'function') {
    const bitmap = await createImageBitmap(file)
    return { image: bitmap, close: () => bitmap.close?.() }
  }
  const url = URL.createObjectURL(file)
  try {
    const image = new Image()
    image.src = url
    if (image.decode) await image.decode()
    else await new Promise((resolve, reject) => { image.onload = resolve; image.onerror = reject })
    return { image, close: () => URL.revokeObjectURL(url) }
  } catch (error) {
    URL.revokeObjectURL(url)
    throw new Error('This image could not be opened. Try a JPEG, PNG, or WebP file.')
  }
}

export async function prepareProductImage(file) {
  const validationError = validateProductImage(file)
  if (validationError) throw new Error(validationError)

  const { image, close } = await loadImage(file)
  try {
    const sourceWidth = image.width || image.naturalWidth
    const sourceHeight = image.height || image.naturalHeight
    if (!sourceWidth || !sourceHeight) throw new Error('This image could not be opened. Try another image.')
    const scale = Math.min(1, PRODUCT_IMAGE_SIZE / Math.max(sourceWidth, sourceHeight))
    const canvas = document.createElement('canvas')
    canvas.width = Math.max(1, Math.round(sourceWidth * scale))
    canvas.height = Math.max(1, Math.round(sourceHeight * scale))
    const context = canvas.getContext('2d')
    if (!context) throw new Error('Image processing is unavailable in this browser.')
    context.drawImage(image, 0, 0, canvas.width, canvas.height)

    let blob = await canvasBlob(canvas, 'image/webp', 0.82)
    if (blob.type !== 'image/webp') {
      context.save()
      context.globalCompositeOperation = 'destination-over'
      context.fillStyle = '#fff'
      context.fillRect(0, 0, canvas.width, canvas.height)
      context.restore()
      blob = await canvasBlob(canvas, 'image/jpeg', 0.82)
    }
    if (blob.type === 'image/jpeg' && blob.size > PRODUCT_IMAGE_TARGET_BYTES) {
      const smaller = await canvasBlob(canvas, 'image/jpeg', 0.68)
      if (smaller.size < blob.size) blob = smaller
    }
    if (blob.size > MAX_PRODUCT_IMAGE_BYTES) throw new Error('The resized image is still too large. Choose another image.')
    const extension = blob.type === 'image/webp' ? 'webp' : blob.type === 'image/jpeg' ? 'jpg' : 'png'
    const baseName = (file.name || 'product-image').replace(/\.[^.]+$/, '').replace(/[^a-z0-9_-]+/gi, '-').slice(0, 80) || 'product-image'
    return new File([blob], `${baseName}.${extension}`, { type: blob.type, lastModified: Date.now() })
  } finally {
    close()
  }
}

export function productImagePath(businessId, productId, file) {
  const safeName = file.name.toLowerCase().replace(/[^a-z0-9._-]+/g, '-')
  return `${businessId}/${productId}/${crypto.randomUUID()}-${safeName}`
}
