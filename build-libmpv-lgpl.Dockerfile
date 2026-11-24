# Strictly-LGPLv2.1+ cross-compilation container for Plekt VR (Meta Quest 3 / arm64-v8a)
# Builds dynamically linked FFmpeg (MediaCodec JNI, NO --enable-gpl, NO --enable-nonfree),
# dav1d, freetype2, fribidi, harfbuzz, libass, libplacebo, and libmpv.so.

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV ANDROID_NDK_VERSION=r27c
ENV ANDROID_API=34
ENV ARCH=arm64-v8a
ENV TARGET=aarch64-linux-android

RUN apt-get update && apt-get install -y --no-install-recommends \
    autoconf automake autopoint build-essential ca-certificates cmake curl \
    git gperf libtool meson ninja-build patch pkg-config python3 python3-pip \
    unzip xz-utils yasm nasm && \
    rm -rf /var/lib/apt/lists/*

# Install Android NDK r27c (Linux x86_64 host)
RUN mkdir -p /opt/android-ndk && \
    curl -fsSL "https://dl.google.com/android/repository/android-ndk-${ANDROID_NDK_VERSION}-linux.zip" -o /tmp/ndk.zip && \
    unzip -q /tmp/ndk.zip -d /opt/android-ndk && \
    rm /tmp/ndk.zip

ENV ANDROID_NDK_HOME=/opt/android-ndk/android-ndk-${ANDROID_NDK_VERSION}
ENV TOOLCHAIN=${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64
ENV PATH=${TOOLCHAIN}/bin:${PATH}

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3-glad python3-jinja2 && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY build-libmpv-lgpl.sh /build/build-libmpv-lgpl.sh
COPY patches/ /build/patches/
RUN chmod +x /build/build-libmpv-lgpl.sh

ENTRYPOINT ["/build/build-libmpv-lgpl.sh"]
