#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Plekt VR Strictly-LGPLv2.1+ Android arm64-v8a Media Core Build Script
# ------------------------------------------------------------------------------
# Builds: dav1d, freetype2, fribidi, harfbuzz, libass, FFmpeg (LGPLv2.1+),
#         libplacebo, and libmpv (LGPLv2.1+, dynamically linked .so).
#
# Outputs BOTH build profiles in a single reproducible run:
#   - /out/debug/jniLibs/arm64-v8a    : Full LGPLv2.1+ FFmpeg decoder set (development)
#   - /out/release/jniLibs/arm64-v8a  : Release decoder set (MediaCodec video +
#                                       royalty-free / expired audio, video & subtitle decoders)
#
# Compliance guarantees:
#   - FFmpeg is built WITHOUT --enable-gpl, WITHOUT --enable-nonfree, and WITHOUT --enable-version3.
#   - HTTPS streams are proxied through Android's OkHttp loopback proxy (HttpStreamProxy),
#     so FFmpeg needs no bundled TLS library (no mbedTLS / LGPLv3 dependency).
#   - mpv is built with -Dgpl=false (LGPLv2.1+ mode).
#   - Exact source tarballs + configure logs are exported to /out/lgpl-sources/.
# ==============================================================================

PREFIX="/build/prefix"
SRC="/build/src"
OUT_DEBUG_LIBS="/out/debug/jniLibs/arm64-v8a"
OUT_RELEASE_LIBS="/out/release/jniLibs/arm64-v8a"
OUT_INC="/out/include"
OUT_SOURCES="/out/lgpl-sources"
PATCH_DIR="/build/patches"
JOBS="$(nproc)"

mkdir -p "${PREFIX}" "${SRC}" "${OUT_DEBUG_LIBS}" "${OUT_RELEASE_LIBS}" "${OUT_INC}" "${OUT_SOURCES}"

export CC="${TOOLCHAIN}/bin/${TARGET}${ANDROID_API}-clang"
export CXX="${TOOLCHAIN}/bin/${TARGET}${ANDROID_API}-clang++"
export AR="${TOOLCHAIN}/bin/llvm-ar"
export AS="${CC}"
export LD="${TOOLCHAIN}/bin/ld.lld"
export RANLIB="${TOOLCHAIN}/bin/llvm-ranlib"
export STRIP="${TOOLCHAIN}/bin/llvm-strip"
export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="${PREFIX}/lib/pkgconfig"
export CFLAGS="-O3 -fPIC -I${PREFIX}/include"
export CXXFLAGS="-O3 -fPIC -I${PREFIX}/include"
export LDFLAGS="-L${PREFIX}/lib -Wl,-z,max-page-size=16384"

# Generate Meson cross file for Android arm64-v8a
CROSS_FILE="/build/android-arm64.cross"
cat > "${CROSS_FILE}" <<EOF
[binaries]
c = '${CC}'
cpp = '${CXX}'
ar = '${AR}'
strip = '${STRIP}'
pkg-config = 'pkg-config'

[built-in options]
c_args = ['-O3', '-fPIC', '-I${PREFIX}/include']
cpp_args = ['-O3', '-fPIC', '-I${PREFIX}/include']
c_link_args = ['-L${PREFIX}/lib', '-Wl,-z,max-page-size=16384']
cpp_link_args = ['-L${PREFIX}/lib', '-Wl,-z,max-page-size=16384']

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
EOF

fetch_tarball() {
    local name="$1"
    local url="$2"
    local file="${OUT_SOURCES}/${name}"
    if [[ ! -f "${file}" ]]; then
        echo "==> Downloading ${name}" >&2
        curl -fsSL --retry 2 "${url}" -o "${file}.part" || return
        mv "${file}.part" "${file}"
    fi
    local dir="${SRC}/${name%.tar.*}"
    rm -rf "${dir}"
    mkdir -p "${dir}"
    tar -xf "${file}" -C "${dir}" --strip-components=1 || return
    echo "${dir}"
}

export_shared_libs() {
    local dest="$1"
    local libraries=(mpv avcodec avdevice avfilter avformat avutil swresample swscale dav1d fribidi ass placebo)
    for name in "${libraries[@]}"; do
        local filename="lib${name}.so"
        local library="${PREFIX}/lib/${filename}"
        if ! llvm-readelf -d "${library}" | grep -F '(SONAME)' | grep -F "[${filename}]" >/dev/null; then
            echo "Unexpected Android SONAME for ${library}" >&2
            exit 1
        fi
        cp -L "${library}" "${dest}/"
    done
}

build_ffmpeg() {
    local profile="$1"
    local log_file="${OUT_SOURCES}/ffmpeg-configure-${profile}.log"
    local dir
    dir=$(fetch_tarball "ffmpeg-${FFMPEG_VER}.tar.xz" "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VER}.tar.xz")

    # LGPL patches (exported with the sources): route AC-3/E-AC-3 and platform
    # software-only audio decoders (Dolby, AAC) through Android MediaCodec.
    local patch
    for patch in "${PATCH_DIR}"/ffmpeg-${FFMPEG_VER}-*.patch; do
        [[ -f "${patch}" ]] || continue
        patch -d "${dir}" -p1 --forward < "${patch}" || exit 1
        cp "${patch}" "${OUT_SOURCES}/"
    done

    local extra_flags=()
    if [[ "${profile}" == "release" ]]; then
        # Release build: ship ONLY MediaCodec hardware video wrappers + royalty-free / expired
        # software decoders and subtitle decoders (zero software H.264/HEVC/MPEG-2/VC-1/DTS/TrueHD).
        extra_flags+=(
            --disable-decoders --disable-encoders
            --enable-decoder=h264_mediacodec,hevc_mediacodec,vp8_mediacodec,vp9_mediacodec,av1_mediacodec,mpeg4_mediacodec
            --enable-decoder=libdav1d,vp8,vp9,mjpeg,png,webp
            --enable-decoder=opus,vorbis,flac,mp3,mp3float,mp3_mediacodec,mp2,mp2float,aac_mediacodec,alac
            --enable-decoder=ac3_mediacodec,eac3_mediacodec
            --enable-decoder='pcm_*'
            --enable-decoder='adpcm_*'
            --enable-decoder=ass,ssa,subrip,srt,webvtt,mov_text,text,pgssub,dvdsub,dvbsub,xsub,jacosub,microdvd,mpl2,pjs,realtext,sami,stl,subviewer,subviewer1,vplayer,ccaption
        )
    fi

    (
        cd "${dir}"
        ./configure \
            --prefix="${PREFIX}" \
            --target-os=android \
            --arch=aarch64 \
            --enable-cross-compile \
            --cc="${CC}" \
            --cxx="${CXX}" \
            --ar="${AR}" \
            --ranlib="${RANLIB}" \
            --strip="${STRIP}" \
            --nm="${TOOLCHAIN}/bin/llvm-nm" \
            --enable-shared \
            --disable-static \
            --disable-gpl \
            --disable-nonfree \
            --disable-version3 \
            --disable-protocol=https,tls \
            --disable-programs \
            --disable-doc \
            --disable-debug \
            --enable-jni \
            --enable-mediacodec \
            --enable-libdav1d \
            --enable-neon \
            --enable-asm \
            --extra-cflags="${CFLAGS}" \
            --extra-ldflags="${LDFLAGS}" \
            "${extra_flags[@]}" \
            | tee "${log_file}"

        if ! grep -F "License: LGPL version 2.1 or later" "${log_file}" >/dev/null; then
            echo "ERROR: FFmpeg (${profile}) is NOT pure LGPL version 2.1 or later!" >&2
            exit 1
        fi
        if [[ "${profile}" == "release" ]]; then
            for decoder in AAC AAC_FIXED DCA TRUEHD MLP AC3 EAC3 H264 HEVC MPEG2VIDEO MPEG4 VC1; do
                if grep -qx "#define CONFIG_${decoder}_DECODER 1" config_components.h; then
                    echo "ERROR: Release FFmpeg unexpectedly enables the ${decoder} software decoder." >&2
                    exit 1
                fi
            done
            for decoder in AAC_MEDIACODEC AC3_MEDIACODEC EAC3_MEDIACODEC H264_MEDIACODEC HEVC_MEDIACODEC; do
                if ! grep -qx "#define CONFIG_${decoder}_DECODER 1" config_components.h; then
                    echo "ERROR: Release FFmpeg is missing the ${decoder} decoder." >&2
                    exit 1
                fi
            done
        fi

        make -j"${JOBS}"
        make install
    )
}

build_mpv() {
    local profile="$1"
    local dir
    dir=$(fetch_tarball "mpv-${MPV_VER}.tar.gz" "https://github.com/mpv-player/mpv/archive/refs/tags/v${MPV_VER}.tar.gz")
    meson setup "${dir}/build" "${dir}" --cross-file "${CROSS_FILE}" \
        --prefix="${PREFIX}" \
        -Dgpl=false \
        -Dlibmpv=true \
        -Dcplayer=false \
        -Dandroid-media-ndk=enabled \
        -Degl-android=enabled \
        -Dopensles=enabled \
        -Dlua=disabled \
        -Djavascript=disabled \
        -Dmanpage-build=disabled \
        -Dhtml-build=disabled \
        | tee "${OUT_SOURCES}/mpv-configure-${profile}.log"
    ninja -C "${dir}/build" -j"${JOBS}" install
}

# Pinned reproducible versions
DAV1D_VER="1.5.0"
FREETYPE_VER="2.13.3"
FRIBIDI_VER="1.0.16"
HARFBUZZ_VER="10.1.0"
LIBASS_VER="0.17.3"
FFMPEG_VER="7.1"
LIBPLACEBO_VER="7.349.0"
# libplacebo's release archive omits the sources of its Git submodules.
FAST_FLOAT_REV="2b2395f9ac836ffca6404424bcc252bff7aa80e4"
MPV_VER="0.39.0"

echo "=== [1/8] dav1d ${DAV1D_VER} (BSD-2-Clause) ==="
DIR=$(fetch_tarball "dav1d-${DAV1D_VER}.tar.xz" "https://downloads.videolan.org/pub/videolan/dav1d/${DAV1D_VER}/dav1d-${DAV1D_VER}.tar.xz")
meson setup "${DIR}/build" "${DIR}" --cross-file "${CROSS_FILE}" \
    --prefix="${PREFIX}" --default-library=shared -Denable_tools=false -Denable_tests=false
ninja -C "${DIR}/build" -j"${JOBS}" install

echo "=== [2/8] FreeType ${FREETYPE_VER} (FTL) ==="
DIR=$(fetch_tarball "freetype-${FREETYPE_VER}.tar.xz" "https://download.savannah.gnu.org/releases/freetype/freetype-${FREETYPE_VER}.tar.xz")
meson setup "${DIR}/build" "${DIR}" --cross-file "${CROSS_FILE}" \
    --prefix="${PREFIX}" --default-library=static \
    -Dbrotli=disabled -Dbzip2=disabled -Dharfbuzz=disabled -Dpng=disabled -Dzlib=system
ninja -C "${DIR}/build" -j"${JOBS}" install

echo "=== [3/8] FriBidi ${FRIBIDI_VER} (LGPLv2.1+) ==="
DIR=$(fetch_tarball "fribidi-${FRIBIDI_VER}.tar.xz" "https://github.com/fribidi/fribidi/releases/download/v${FRIBIDI_VER}/fribidi-${FRIBIDI_VER}.tar.xz")
meson setup "${DIR}/build" "${DIR}" --cross-file "${CROSS_FILE}" \
    --prefix="${PREFIX}" --default-library=shared -Ddocs=false -Dbin=false -Dtests=false
ninja -C "${DIR}/build" -j"${JOBS}" install

echo "=== [4/8] HarfBuzz ${HARFBUZZ_VER} (MIT) ==="
DIR=$(fetch_tarball "harfbuzz-${HARFBUZZ_VER}.tar.xz" "https://github.com/harfbuzz/harfbuzz/releases/download/${HARFBUZZ_VER}/harfbuzz-${HARFBUZZ_VER}.tar.xz")
meson setup "${DIR}/build" "${DIR}" --cross-file "${CROSS_FILE}" \
    --prefix="${PREFIX}" --default-library=static \
    -Dtests=disabled -Ddocs=disabled -Dutilities=disabled -Dicu=disabled -Dglib=disabled -Dfreetype=enabled
ninja -C "${DIR}/build" -j"${JOBS}" install

echo "=== [5/8] libass ${LIBASS_VER} (ISC) ==="
DIR=$(fetch_tarball "libass-${LIBASS_VER}.tar.xz" "https://github.com/libass/libass/releases/download/${LIBASS_VER}/libass-${LIBASS_VER}.tar.xz")
meson setup "${DIR}/build" "${DIR}" --cross-file "${CROSS_FILE}" \
    --prefix="${PREFIX}" --default-library=shared \
    -Dfontconfig=disabled -Drequire-system-font-provider=false -Dtest=false
ninja -C "${DIR}/build" -j"${JOBS}" install

echo "=== [6/8] libplacebo ${LIBPLACEBO_VER} (LGPLv2.1+) ==="
DIR=$(fetch_tarball "libplacebo-v${LIBPLACEBO_VER}.tar.gz" "https://code.videolan.org/videolan/libplacebo/-/archive/v${LIBPLACEBO_VER}/libplacebo-v${LIBPLACEBO_VER}.tar.gz")
FAST_FLOAT_DIR=$(fetch_tarball "fast_float-${FAST_FLOAT_REV}.tar.gz" "https://github.com/fastfloat/fast_float/archive/${FAST_FLOAT_REV}.tar.gz")
mkdir -p "${DIR}/3rdparty/fast_float"
cp -R "${FAST_FLOAT_DIR}/include" "${DIR}/3rdparty/fast_float/"
meson setup "${DIR}/build" "${DIR}" --cross-file "${CROSS_FILE}" \
    --prefix="${PREFIX}" --default-library=shared \
    -Dvulkan=disabled -Dopengl=enabled -Ddemos=false -Dtests=false -Dshaderc=disabled -Dlcms=disabled
ninja -C "${DIR}/build" -j"${JOBS}" install

echo "=== [7/8] FFmpeg ${FFMPEG_VER} (DEBUG PROFILE - STRICT LGPLv2.1+) ==="
build_ffmpeg "debug"

echo "=== [8/8] libmpv ${MPV_VER} (STRICT LGPLv2.1+ SHARED) ==="
build_mpv "debug"
export_shared_libs "${OUT_DEBUG_LIBS}"

rm -rf "${OUT_INC}/mpv"
cp -r "${PREFIX}/include/mpv" "${OUT_INC}/mpv"

echo "=== [7b/8] FFmpeg ${FFMPEG_VER} (RELEASE PROFILE - STRICT LGPLv2.1+ LICENSED/ROYALTY-FREE DECODERS) ==="
build_ffmpeg "release"
build_mpv "release"
export_shared_libs "${OUT_RELEASE_LIBS}"

echo "=== Verifying SONAMEs & LGPLv2.1+ build summary ==="
echo "--- DEBUG ---"
ls -lh "${OUT_DEBUG_LIBS}"
echo "--- RELEASE ---"
ls -lh "${OUT_RELEASE_LIBS}"
echo "DONE: Pure LGPLv2.1+ arm64-v8a debug & release binaries written to /out/{debug,release}/jniLibs/arm64-v8a"
