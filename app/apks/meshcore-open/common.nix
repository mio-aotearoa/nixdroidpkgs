{ fetchFromGitHub }:
let
  version = "99.0.4+1403";
in
{
  inherit version;

  src = fetchFromGitHub {
    owner = "jade-on-mesh";
    repo = "meshcore-open-tak";
    # latest-build is a moving tag; pin the release commit for reproducibility.
    rev = "58b3500af4c9403a1bc4ed73b8bf163e1588122f";
    hash = "sha256-Goa+QzULAmFpbvqovDHq/V65N/nPdNYiGnvlKx4VbII=";
  };

  # Shared with the iOS package so platform builds carry the same downstream
  # channel-resend behavior and source revision.
  patches = [ ./resend-channel-messages.patch ];
}
