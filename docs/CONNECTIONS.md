# Connecting a phone

VibePier requires an approved device for every remote feature. The old VibeBar app and protocol are not used by the new app.

## First connection

1. Start VibePier on the Mac and open VibePier on the Android phone.
2. On a fresh installation, the phone selects Bluetooth and asks for the required nearby-device permission.
3. Once the phone discovers the Mac, it requests authorization automatically. Confirm **Allow this phone** on the Mac. Opening the conversation screen is not required.
4. The phone negotiates its authenticated channel and displays the current Mac application.

Discovery exposes only availability. It does not expose application names, conversation data, settings, or control access. The Mac confirmation authorizes that phone to use remote controls and supported AI-session features. Usage tracking and automatic unlock remain separate opt-in features.

An automatic request is sent once per Bluetooth connection. Discovery updates do not repeatedly open the confirmation dialog while approval is pending or after rejection. An existing authorized phone reconnects without another approval. Removing its authorization on the Mac stops its access.

## Cloud relay

Deploy the [self-hosted relay](../services/relay/README.md), then save its WSS endpoint, room, and server secret in the Mac app's relay settings. Relay credentials are stored in the Mac Keychain; the ordinary JSON configuration stores the endpoint and room.

An approved phone connected over Bluetooth can automatically retrieve the Mac's relay configuration. This transfer uses both the authenticated control channel and the encrypted session channel. The phone encrypts the saved relay settings with an Android Keystore key. The relay configuration does not grant device authorization on its own.

Select **Cloud relay** in the phone's connection settings. The Mac should report an online phone. The relay may negotiate a direct UDP path; when this succeeds the phone displays **Direct connection · Ready**. The relay remains available as the fallback and carries session traffic. Relayed voice controls use the Mac microphone; phone microphone packets require Bluetooth, local Wi-Fi, or an established direct path.

## Troubleshooting

- **Waiting for Mac confirmation:** approve the request on the Mac. If it was rejected or timed out, reconnect Bluetooth or explicitly request authorization again from the session menu.
- **Mac not found:** check Bluetooth and nearby-device permissions on both devices, and confirm the new Mac app is running.
- **Relay connected, waiting for phone:** confirm the phone has received relay settings and selected cloud relay. It must also have completed device authorization.
- **Relay connection fails:** check the WSS certificate, reverse proxy route, server service, room, and secret. Do not disable certificate validation or use an unauthenticated fallback.

## Validation scope

The current development build has been verified with real Mi 10 and 25053RT47C phones: encrypted Bluetooth application-state synchronization, authorization preserved across signed APK updates, and both phones online simultaneously through the new relay. The Mac also negotiated direct UDP routes, including IPv6. The user confirmed both relay connections work. Cellular-only fallback and extended background behavior remain separate release acceptance checks.

## Lock and unlock

The session-list menu includes **Lock** and **Unlock**. Both require an authorized, connected phone. Locking is refused while a desktop input operation is active, and the phone asks you to retry later. Unlocking uses the password explicitly configured through the existing Mac unlock settings. If no password is configured, the phone opens that setup screen.

An explicit unlock keeps the desktop unlocked. Automatic temporary unlock for a desktop action still relocks after the last action finishes, unless you explicitly chose Unlock in the meantime. A failed password-based unlock is not repeatedly retried; reconfigure the credential or unlock the Mac manually. Replies confirm the observed screen state; an interrupted connection reports an unconfirmed result rather than automatically repeating a command.
