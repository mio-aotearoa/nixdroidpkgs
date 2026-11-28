{ fetchFromGitHub }:
let
  version = "99.0.4+1402";
in
{
  inherit version;

  src = fetchFromGitHub {
    owner = "jade-on-mesh";
    repo = "meshcore-open-tak";
    # latest-build is a moving tag; pin the release commit for reproducibility.
    rev = "907114945a3b56fc63727541e0da8532636d728b";
    hash = "sha256-Sbbp4ge9N5CFN0KeFV8KBW8K9cnUKXB4QdSpPN7ExCk=";
  };

  # Shared with the iOS package so platform builds carry the same downstream
  # channel-resend behavior and source revision.
  patches = [ ./resend-channel-messages.patch ];
}
