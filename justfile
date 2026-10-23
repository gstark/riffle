default:
    @just --list

# Build and push the search image, then apply the infrastructure. tofu asks before it applies.
deploy-search:
    #!/usr/bin/env bash
    set -euo pipefail
    export AWS_PROFILE="${AWS_PROFILE:-automation}"
    scripts/build-search-image.sh
    tofu -chdir=infra apply

# Build Riffle, install it in /Applications, and restart it.
riffle:
    #!/usr/bin/env bash
    set -euo pipefail
    cd apps/macos/Riffle
    if [[ ! -f Local.xcconfig ]]; then
        # The team ID is the OU field of the Apple Development certificate.
        team=$(security find-certificate -c "Apple Development" -p 2>/dev/null \
            | openssl x509 -noout -subject | grep -oE 'OU ?= ?[A-Z0-9]{10}' | grep -oE '[A-Z0-9]{10}$' || true)
        if [[ -z "$team" ]]; then
            echo "No Apple Development certificate found. Add your Apple account in Xcode > Settings > Accounts," >&2
            echo "or copy apps/macos/Riffle/Local.xcconfig.example to Local.xcconfig and set DEVELOPMENT_TEAM." >&2
            exit 1
        fi
        echo "DEVELOPMENT_TEAM = $team" > Local.xcconfig
        echo "Made apps/macos/Riffle/Local.xcconfig with team $team."
    fi
    xcodegen generate --quiet
    xcodebuild -scheme Riffle -configuration Release -derivedDataPath build -quiet build
    if pgrep -xq Riffle; then
        osascript -e 'tell application id "com.gstark.riffle" to quit'
        for _ in {1..50}; do pgrep -xq Riffle || break; sleep 0.1; done
        pkill -x Riffle || true
    fi
    rm -rf /Applications/Riffle.app
    ditto build/Build/Products/Release/Riffle.app /Applications/Riffle.app
    open /Applications/Riffle.app
