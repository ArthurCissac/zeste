#!/bin/zsh
# Compile un ffmpeg/ffprobe autonome (LGPL, statique, macOS 14+) à embarquer dans Zeste.
# Sources : ffmpeg.org (signature GPG vérifiée) et les archives de Homebrew (empreintes vérifiées).
# Résultat : vendor/ffmpeg-8.0/ffmpeg et ffprobe, sans dépendance hors système.
set -euo pipefail
cd "$(dirname "$0")/.."
B=$PWD/vendor; P=$B/deps2; C=$(brew --cache)/downloads
mkdir -p $B/src $P && cd $B

[[ -f ffmpeg-8.0.tar.xz ]] || curl -fsSLO https://ffmpeg.org/releases/ffmpeg-8.0.tar.xz
[[ -f ffmpeg-8.0.tar.xz.asc ]] || curl -fsSLO https://ffmpeg.org/releases/ffmpeg-8.0.tar.xz.asc
curl -fsSL https://ffmpeg.org/ffmpeg-devel.asc -o ffmpeg-devel.asc
export GNUPGHOME=$(mktemp -d)
gpg --quiet --import ffmpeg-devel.asc
# Clé officielle FFmpeg : FCF9 86EA 15E6 E293 A564 4F10 B432 2F04 D676 58D8
gpg --verify ffmpeg-8.0.tar.xz.asc ffmpeg-8.0.tar.xz

brew fetch --build-from-source lame opus libogg libvorbis libvpx webp
cd src
for t in libogg-1.3.6.tar.gz libvorbis-1.3.7.tar.xz opus-1.6.1.tar.gz lame-4.0.tar.gz libwebp-1.6.0.tar.gz libvpx-1.17.0.tar.gz; do
  tar xf $C/*--$t
done

export MACOSX_DEPLOYMENT_TARGET=14.0 CFLAGS="-O2 -mmacosx-version-min=14.0" CXXFLAGS="-O2 -mmacosx-version-min=14.0"
export LDFLAGS="-mmacosx-version-min=14.0" PKG_CONFIG_LIBDIR=$P/lib/pkgconfig
b() { local d=$1; shift; (cd $B/src/$d && ./configure --prefix=$P --disable-shared --enable-static "$@" && make -j10 && make install); }
b libogg-1.3.6
sed -i '' 's/-force_cpusubtype_ALL//g' $B/src/libvorbis-1.3.7/configure
b libvorbis-1.3.7 --with-ogg=$P --disable-examples --disable-docs
b opus-1.6.1 --disable-doc --disable-extra-programs
b lame-4.0 --disable-frontend --disable-decoder
b libwebp-1.6.0 --enable-libwebpmux --disable-libwebpdemux --disable-gif --disable-gl --disable-sdl --disable-png --disable-jpeg --disable-tiff
(cd $B/src/libvpx-1.17.0 && ./configure --prefix=$P --disable-shared --enable-static --disable-examples --disable-tools \
  --disable-docs --disable-unit-tests --extra-cflags="-mmacosx-version-min=14.0" && make -j10 && make install)

cd $B && rm -rf ffmpeg-8.0 && tar xf ffmpeg-8.0.tar.xz && cd ffmpeg-8.0
./configure --prefix=$B/out --arch=arm64 --cc=clang \
  --enable-static --disable-shared --disable-ffplay --disable-doc --disable-debug --disable-network --disable-autodetect \
  --enable-videotoolbox --enable-audiotoolbox --enable-zlib --enable-bzlib \
  --enable-libmp3lame --enable-libopus --enable-libvorbis --enable-libvpx --enable-libwebp \
  --pkg-config-flags=--static --extra-cflags="-I$P/include -mmacosx-version-min=14.0" --extra-ldflags="-L$P/lib -mmacosx-version-min=14.0"
make -j10
echo "ffmpeg prêt : $B/ffmpeg-8.0/ffmpeg"
