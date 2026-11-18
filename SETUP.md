# Locus — install & first teleport

## 1. Install Locus

Build this checkout and install the **Locus** target directly on an iPhone running iOS 17.6 or later. The signed app must include its signed `PlugIns/TunnelProv.appex` extension. Both signing profiles need the Network Extensions packet tunnel entitlement. [Build instructions](README.md#build)

Bundle ID: `com.chrismack.locus`

If you already use Locus with the standalone LocalDevVPN app, stop the current simulation and disconnect the old VPN. An in-place update with the same app identifier and team keeps Locus’s saved pairing file and favorites. Connect the built-in VPN once to authorize the new Locus profile.

## 2. Pairing

### On iOS 27 — no computer

1. Open Locus → **Settings → Pair on this iPhone** → **Start pairing**.
2. Allow **Local Network** (and Location / Notifications if asked).
3. Leave Locus open. Go to **Settings › Privacy & Security › Developer Mode › Pair with Host**.
4. Pick **Locus** → **Pair**.
5. Enter your **iPhone unlock passcode** first (authorizes pairing).
6. Stay in Settings. Read the **6-digit code** from the Locus notification banner and enter it in the second prompt.
7. Return to Locus and check for **Paired**. If Settings reports an interrupted connection, choose **Restart pairing** in Locus and use the new attempt’s code.

### On iOS 17.6–26

1. On a computer, download [idevice_pair](https://github.com/jkcoxson/idevice_pair/releases).
2. Plug in your iPhone, unlock, Trust.
3. Generate an **RPPairing** file (not lockdown / SideStore `.mobiledevicepairing`).
4. AirDrop / Share → Open in **Locus**, **Import**, or **Paste from clipboard**.

## 3. Connect the built-in VPN

Tap **Connect VPN** in the VPN setup step or in Locus Settings. Approve the iOS request to add a VPN configuration. When Locus reports **Connected**, the system tunnel is ready. With the default settings, the device address is `10.7.0.1` and the VPN interface address is `10.7.1.1`.

## 4. Teleport

Connect to Wi-Fi, drop a pin on the map and tap **Teleport**. Check your current location in Apple Maps. **Stop** ends the location simulation. You can disconnect the VPN separately in Locus Settings.
