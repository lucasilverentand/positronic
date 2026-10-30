# Local voice processing provenance

These libraries are compiled into the app. No Homebrew installation, system voice
processing, network connection, runtime download or hosted service is required.
The small RNNoise speech-denoising network is embedded in upstream C source.

- SpeexDSP 1.2.1: https://downloads.xiph.org/releases/speex/speexdsp-1.2.1.tar.gz
  SHA-256 `8c777343e4a6399569c72abc38a95b24db56882c83dbdb6c6424a5f4aeb54d3d`.
  Selected echo cancellation, resampling and smallft FFT sources/headers.
  Local generated config uses floating point, smallft, standard integer types.
- RNNoise 0.1.1, immutable commit
  `6cbfd53eb348a8d394e0757b4025c6ded34eb2b6`:
  https://github.com/xiph/rnnoise/tree/6cbfd53eb348a8d394e0757b4025c6ded34eb2b6
  Source archive SHA-256
  `5900832175a507e1ee5d4d596ff2c2b3a4eb66c59d2a12d33095c79e673e953d`.
  Portable floating-point sources, embedded original network, standard C math.

Upstream source is otherwise unchanged. The small config/type headers are generated
locally; no upstream configure scripts run at app launch. Both COPYING files are
retained and packaged with the signed app. RNNoise common tables initialize once
before concurrent streams can process audio. Each stream owns independent adaptive
and neural state. No speaker identity, recording or transcript is stored.
