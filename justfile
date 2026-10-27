default:
    @just --list

# Build the sync Lambda bundle and apply the infrastructure. tofu asks before it applies.
deploy:
    #!/usr/bin/env bash
    set -euo pipefail
    export AWS_PROFILE="${AWS_PROFILE:-automation}"
    if [[ ! -f infra/backend.hcl ]]; then
        echo "infra/backend.hcl is missing. See README.md, Infrastructure." >&2
        exit 1
    fi
    tofu -chdir=infra init -backend-config=backend.hcl -input=false >/dev/null
    npm run build:lambda
    tofu -chdir=infra apply

# Build and push the search image, then deploy.
deploy-search:
    #!/usr/bin/env bash
    set -euo pipefail
    export AWS_PROFILE="${AWS_PROFILE:-automation}"
    tofu -chdir=infra init -backend-config=backend.hcl -input=false >/dev/null
    scripts/build-search-image.sh
    just deploy

# Build a signed Release Riffle.app into apps/macos/Riffle/build.
riffle-build:
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

# Build Riffle, install it in /Applications, and restart it.
riffle: riffle-build
    #!/usr/bin/env bash
    set -euo pipefail
    if pgrep -xq Riffle; then
        osascript -e 'tell application id "com.gstark.riffle" to quit'
        for _ in {1..50}; do pgrep -xq Riffle || break; sleep 0.1; done
        pkill -x Riffle || true
    fi
    rm -rf /Applications/Riffle.app
    ditto apps/macos/Riffle/build/Build/Products/Release/Riffle.app /Applications/Riffle.app
    open /Applications/Riffle.app

# Build Riffle, publish a GitHub release, and update the cask in the gstark/tap Homebrew tap.
homebrew:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ -n "$(git status --porcelain)" ]]; then
        echo "The working tree has changes. Commit them first." >&2
        exit 1
    fi

    base=$(/usr/bin/awk '/CFBundleShortVersionString:/ { gsub(/"/, "", $2); print $2; exit }' apps/macos/Riffle/project.yml)
    version="$base-$(/bin/date +%Y%m%d%H%M)"
    zip="apps/macos/Riffle/build/Riffle-$version.zip"

    just riffle-build
    /bin/rm -f apps/macos/Riffle/build/Riffle-*.zip
    /usr/bin/ditto -c -k --keepParent apps/macos/Riffle/build/Build/Products/Release/Riffle.app "$zip"
    sha=$(/usr/bin/shasum -a 256 "$zip" | /usr/bin/cut -d' ' -f1)

    git push origin "$(git branch --show-current)"
    gh release create "v$version" "$zip" -R gstark/riffle \
        --target "$(git rev-parse HEAD)" \
        --title "Riffle $version" \
        --notes "Build of $(git rev-parse --short HEAD)."

    tap_dir=$(brew --repository gstark/tap)
    git -C "$tap_dir" pull --ff-only
    cat > "$tap_dir/Casks/riffle.rb" <<EOF
    cask "riffle" do
      version "$version"
      sha256 "$sha"

      url "https://github.com/gstark/riffle/releases/download/v#{version}/Riffle-#{version}.zip"
      name "Riffle"
      desc "Menu bar search for a Gmail backup"
      homepage "https://github.com/gstark/riffle"

      depends_on arch: :arm64
      depends_on macos: :tahoe

      app "Riffle.app"

      # The build is signed but not notarized, so remove the quarantine flag to let it open.
      postflight_steps do
        run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{{{appdir}}/Riffle.app"]
      end

      uninstall quit: "com.gstark.riffle"
    end
    EOF
    git -C "$tap_dir" add Casks/riffle.rb
    git -C "$tap_dir" commit -m "riffle $version"
    git -C "$tap_dir" push

    echo "Released $version. Run 'brew install gstark/tap/riffle' to install it."
