{ fetchFromGitHub }:
let
  version = "99.0.3+1379";
in
{
  inherit version;

  src = fetchFromGitHub {
    owner = "jade-on-mesh";
    repo = "meshcore-open-tak";
    # latest-build is a moving tag; pin the release commit for reproducibility.
    rev = "59d58b439c86b7f77eda8fd37e9c6f5be61d7148";
    hash = "sha256-8uHtcjZKL3D25ADpmUpfN4MMbgXHGL/9Kp9LxrB+VNA=";
  };

  # Shared with the iOS package so platform builds carry the same downstream
  # channel-resend behavior and source revision.
  patches = [ ./resend-channel-messages.patch ];
}
