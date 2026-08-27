---
name: legacy-mac-porting
description: Use when porting, compiling, benchmarking, or debugging vintage Mac OS X (10.3 Panther through 10.5 Leopard) games across PowerPC (G3, G4, G5), Intel (Lion), and Apple Silicon. Covers endianness, AltiVec SIMD, Mach-O fat binaries, and legacy OpenGL.
---

# Vintage Mac OS X Porting & Cross-Compilation Reference

Use this guide when diagnosing compiler errors, endianness bugs, AltiVec crashes, or OpenGL rendering artifacts on Mac OS X 10.3-10.7.

## 1. PowerPC Architecture Classes & CPU Slices

| Arch Slice | CPU Family | Machines in Fleet | AltiVec SIMD | Notes |
|---|---|---|---|---|
| `ppc750` | PowerPC G3 | `yosemite` (iMac G3 / B&W) | **NO** | Never pass `-maltivec`. Max OS 10.3.9 or 10.4.11. |
| `ppc7400` / `ppc7450` | PowerPC G4 | `mini-g4`, `quicksilver`, `sawtooth` | **YES** (`-maltivec`) | Vector data must be 16-byte aligned. |
| `ppc970` | PowerPC G5 | `imac-g5`, `g5-desktop` (Dual 2.7) | **YES** | 64-bit capable, run as 32-bit Mach-O on 10.4/10.5. |
| `i386` | Intel 32-bit | `mini-intel`, `mini-intel2` (Lion 10.7.5) | SSE2 | Core 2 Duo / Core Duo. |
| `x86_64` | Intel 64-bit | `mini-sl` (Snow Leopard 10.6.8) | SSE3/SSE4 | GeForce 9400M / 64-bit Intel. |
| `arm64` | Apple Silicon | Modern macOS 11-15+ | NEON | Host workstation native slice. |

## 2. Endianness Rules (`__BIG_ENDIAN__` vs `__LITTLE_ENDIAN__`)

PowerPC is **Big-Endian**; x86 and arm64 are **Little-Endian**.
- **File Parsing (PAK, BSP, WAD, MD3, WAV):** Assets stored in little-endian format must be swapped when loaded on PowerPC:
  ```c
  #if defined(__BIG_ENDIAN__) || defined(__ppc__) || defined(__POWERPC__)
  uint32_t val = LittleLong(raw_val);
  float fval = LittleFloat(raw_fval);
  #endif
  ```
- **Bitfields & Network Packets:** Do not cast raw structs over network streams without endian conversion (`htons`/`htonl`).

## 3. AltiVec SIMD Guidelines

- AltiVec vectors (`vector float`, `vector unsigned char`) require **16-byte memory alignment**:
  ```c
  __attribute__((aligned(16))) float matrix[16];
  ```
- Unaligned vector loads (`vec_ld`) on PowerPC G4/G5 will silently truncate address bits to 16-byte boundaries or bus error. Use `vec_perm` or aligned buffers.
- Guard AltiVec code with `#ifdef __ALTIVEC__` so non-AltiVec G3 builds compile cleanly.

## 4. Fat Binary Assembly (`lipo`)

Every release binary is a fat Mach-O bundle combining PowerPC and Intel/arm64 slices:
```bash
lipo -create \
  build/bin-ppc750 \
  build/bin-ppc7400 \
  build/bin-ppc970 \
  build/bin-i386 \
  build/bin-x86_64 \
  build/bin-arm64 \
  -output build/game-fat

# Verify slice contents:
lipo -info build/game-fat
```

## 5. Legacy Mac OpenGL (10.3 Panther - 10.5 Leopard)

- **Target standard OpenGL 1.2 / 1.4:** Avoid modern Core Profile shaders; use ARB extensions:
  - `GL_ARB_multitexture`
  - `GL_ARB_vertex_buffer_object` (10.4+)
  - `GL_EXT_compiled_vertex_array`
- **Double-buffering & VSync:** Always initialize AGL / CGL contexts with double buffering and query hardware renderer strings (`glGetString(GL_RENDERER)`).
