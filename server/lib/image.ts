// Image limits from amendment 5: longest side at most 1024 px, PNG or JPEG, under 400 KB.

export const MAX_IMAGE_SIDE = 1024;
export const MAX_IMAGE_BYTES = 400 * 1024;

export type ImageInfo = { data: Buffer; mediaType: "image/png" | "image/jpeg"; width: number; height: number; bytes: number };
export type ImageCheck = { ok: true; image: ImageInfo } | { ok: false; reason: string; bytes?: number };

const PNG_SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

function pngSize(b: Buffer): { width: number; height: number } | undefined {
  if (b.length < 24 || !b.subarray(0, 8).equals(PNG_SIGNATURE)) return undefined;
  if (b.toString("ascii", 12, 16) !== "IHDR") return undefined;
  return { width: b.readUInt32BE(16), height: b.readUInt32BE(20) };
}

function jpegSize(b: Buffer): { width: number; height: number } | undefined {
  if (b.length < 4 || b[0] !== 0xff || b[1] !== 0xd8) return undefined;
  let i = 2;
  while (i + 9 < b.length) {
    if (b[i] !== 0xff) {
      i += 1;
      continue;
    }
    const marker = b[i + 1] ?? 0;
    if (marker === 0xff) {
      i += 1;
      continue;
    }
    // Start-of-frame markers carry the size; C4, C8 and CC are not frames.
    if (marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc) {
      return { height: b.readUInt16BE(i + 5), width: b.readUInt16BE(i + 7) };
    }
    if (marker === 0xd8 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) {
      i += 2;
      continue;
    }
    i += 2 + b.readUInt16BE(i + 2);
  }
  return undefined;
}

export function checkImage(base64: string): ImageCheck {
  const stripped = base64.replace(/^data:image\/[a-z]+;base64,/i, "");
  const data = Buffer.from(stripped, "base64");
  if (data.length === 0) return { ok: false, reason: "image_empty" };
  if (data.length >= MAX_IMAGE_BYTES) return { ok: false, reason: "image_over_400_KB", bytes: data.length };
  const png = pngSize(data);
  const jpeg = png ? undefined : jpegSize(data);
  const size = png ?? jpeg;
  if (!size) return { ok: false, reason: "image_not_png_or_jpeg", bytes: data.length };
  if (size.width < 1 || size.height < 1) return { ok: false, reason: "image_zero_size", bytes: data.length };
  if (Math.max(size.width, size.height) > MAX_IMAGE_SIDE) {
    return { ok: false, reason: "image_longest_side_over_1024_px", bytes: data.length };
  }
  return {
    ok: true,
    image: { data, mediaType: png ? "image/png" : "image/jpeg", width: size.width, height: size.height, bytes: data.length },
  };
}
