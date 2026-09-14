// Generates assets/icon.ico from scratch (no external tools/deps) — a
// simple purple-gradient square with a white play triangle, matching the
// app's accent color. Produces one 256x256 32bpp BGRA image packed into a
// valid single-image ICO container.
const fs = require('fs');
const path = require('path');

const SIZE = 256;

function lerp(a, b, t) { return a + (b - a) * t; }

// Accent gradient endpoints (matches src/styles.css --accent / --accent2)
const c1 = [139, 92, 246];  // #8B5CF6
const c2 = [168, 85, 247];  // #A855F7

const pixels = Buffer.alloc(SIZE * SIZE * 4); // BGRA

function setPixel(x, y, b, g, r, a) {
  const idx = (y * SIZE + x) * 4;
  pixels[idx] = b;
  pixels[idx + 1] = g;
  pixels[idx + 2] = r;
  pixels[idx + 3] = a;
}

const cx = SIZE / 2, cy = SIZE / 2, radius = SIZE / 2 - 6;
const triSize = SIZE * 0.32;
// Play-triangle vertices, centered, pointing right, nudged slightly right for optical balance
const tOffsetX = SIZE * 0.04;
const p0 = [cx - triSize * 0.5 + tOffsetX, cy - triSize * 0.62];
const p1 = [cx - triSize * 0.5 + tOffsetX, cy + triSize * 0.62];
const p2 = [cx + triSize * 0.66 + tOffsetX, cy];

function sign(px, py, ax, ay, bx, by) {
  return (px - bx) * (ay - by) - (ax - bx) * (py - by);
}
function pointInTriangle(px, py) {
  const d1 = sign(px, py, p0[0], p0[1], p1[0], p1[1]);
  const d2 = sign(px, py, p1[0], p1[1], p2[0], p2[1]);
  const d3 = sign(px, py, p2[0], p2[1], p0[0], p0[1]);
  const hasNeg = d1 < 0 || d2 < 0 || d3 < 0;
  const hasPos = d1 > 0 || d2 > 0 || d3 > 0;
  return !(hasNeg && hasPos);
}

for (let y = 0; y < SIZE; y++) {
  for (let x = 0; x < SIZE; x++) {
    const dx = x - cx, dy = y - cy;
    const distFromCenter = Math.sqrt(dx * dx + dy * dy);

    // Rounded-square mask via superellipse-ish distance (simple rounded rect)
    const rr = SIZE * 0.22; // corner radius
    const half = SIZE / 2 - 4;
    const ax = Math.abs(dx), ay = Math.abs(dy);
    let inside;
    if (ax <= half - rr || ay <= half - rr) {
      inside = ax <= half && ay <= half;
    } else {
      const cornerDx = ax - (half - rr);
      const cornerDy = ay - (half - rr);
      inside = (cornerDx * cornerDx + cornerDy * cornerDy) <= rr * rr;
    }

    if (!inside) {
      setPixel(x, y, 0, 0, 0, 0);
      continue;
    }

    const t = (y / SIZE + x / SIZE) / 2; // diagonal gradient
    const r = Math.round(lerp(c1[0], c2[0], t));
    const g = Math.round(lerp(c1[1], c2[1], t));
    const b = Math.round(lerp(c1[2], c2[2], t));

    if (pointInTriangle(x, y)) {
      setPixel(x, y, 255, 255, 255, 255);
    } else {
      setPixel(x, y, b, g, r, 255);
    }
  }
}

// ---- Pack as ICO (single 256x256 32bpp BITMAPINFOHEADER image) ----
const headerSize = 40;
const imageDataSize = pixels.length; // XOR data (already has alpha, no separate AND needed but ICO spec wants a mask)
const maskRowBytes = Math.ceil(SIZE / 8 / 4) * 4;
const maskSize = maskRowBytes * SIZE;

const bmpHeader = Buffer.alloc(headerSize);
bmpHeader.writeInt32LE(headerSize, 0);      // biSize
bmpHeader.writeInt32LE(SIZE, 4);            // biWidth
bmpHeader.writeInt32LE(SIZE * 2, 8);        // biHeight (doubled: XOR+AND per ICO convention)
bmpHeader.writeInt16LE(1, 12);              // biPlanes
bmpHeader.writeInt16LE(32, 14);             // biBitCount
bmpHeader.writeInt32LE(0, 16);              // biCompression = BI_RGB
bmpHeader.writeInt32LE(imageDataSize, 20);  // biSizeImage
bmpHeader.writeInt32LE(0, 24);
bmpHeader.writeInt32LE(0, 28);
bmpHeader.writeInt32LE(0, 32);
bmpHeader.writeInt32LE(0, 36);

// Bottom-up rows for XOR data
const xorData = Buffer.alloc(imageDataSize);
for (let y = 0; y < SIZE; y++) {
  const srcRow = y;
  const dstRow = SIZE - 1 - y;
  pixels.copy(xorData, dstRow * SIZE * 4, srcRow * SIZE * 4, (srcRow + 1) * SIZE * 4);
}

const andMask = Buffer.alloc(maskSize, 0); // fully opaque via alpha channel; mask left as 0 (opaque)

const imageBuf = Buffer.concat([bmpHeader, xorData, andMask]);

const iconDir = Buffer.alloc(6);
iconDir.writeInt16LE(0, 0);
iconDir.writeInt16LE(1, 2);
iconDir.writeInt16LE(1, 4);

const entry = Buffer.alloc(16);
entry.writeUInt8(0, 0);   // width 0 = 256
entry.writeUInt8(0, 1);   // height 0 = 256
entry.writeUInt8(0, 2);   // color count
entry.writeUInt8(0, 3);   // reserved
entry.writeInt16LE(1, 4); // planes
entry.writeInt16LE(32, 6);// bit count
entry.writeInt32LE(imageBuf.length, 8);
entry.writeInt32LE(6 + 16, 12); // offset

const ico = Buffer.concat([iconDir, entry, imageBuf]);

const outDir = path.join(__dirname, '..', 'assets');
fs.mkdirSync(outDir, { recursive: true });
fs.writeFileSync(path.join(outDir, 'icon.ico'), ico);
console.log('Wrote', path.join(outDir, 'icon.ico'), ico.length, 'bytes');
