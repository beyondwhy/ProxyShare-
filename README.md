# ProxyShare

An iPhone app that shares the phone's internet connection (including an active VPN) with other
devices on the same Wi-Fi, as an HTTP/HTTPS proxy. It keeps running in the background by
playing silent audio, so it doesn't use the iOS VPN slot.

## Build (no Mac needed)

Push this folder to a GitHub repository. The **Build IPA** workflow runs on every push to `main`
(or start it by hand from the Actions tab) and uploads `ProxyShare.ipa` as an artifact.

## Install

1. Download the `ProxyShare-ipa` artifact from the workflow run and unzip it.
2. Install it with [Sideloadly](https://sideloadly.io/) on Windows, signing in with your Apple ID.
3. On the iPhone: Settings → General → VPN & Device Management → trust your Apple ID.
   On iOS 16+, also turn on Settings → Privacy & Security → Developer Mode.

With a free Apple ID the app must be reinstalled every 7 days.

## Use

1. Open ProxyShare, optionally set a password, and turn on **Share connection**. Allow local network access.
2. On the PC, set the manual proxy to the address the app shows (for example `192.168.1.20:8080`).
   With a password, the browser asks for it; any username works.
3. Turn the PC proxy setting off when you stop sharing.
