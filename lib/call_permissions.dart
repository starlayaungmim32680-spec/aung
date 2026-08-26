import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:android_intent_plus/android_intent.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

// Requests the OS-level permissions calls need to reliably reach the
// person even when Fly isn't in the foreground (battery-optimization
// exemption, the "draw over other apps" overlay permission, Android 14's
// full-screen-intent permission, and OEM-specific autostart toggles on
// Xiaomi/Oppo/Vivo/Huawei).
//
// Called only when a call actually starts (see video_call_screen.dart's
// initState) - NOT on app open - so opening Fly never itself triggers a
// permission prompt for someone who's never going to make a call.
//
// Runs at most ONCE per account, regardless of whether the person allows
// or declines each dialog - checked via a flag on their own Firestore
// user doc, since two of these four permissions (full-screen-intent and
// OEM autostart) have no OS-level "already granted" status to check
// against, so without this flag they'd otherwise re-ask on every single
// call. Someone who declined can still turn any of these on later from
// the phone's own Settings.
Future<void> maybeAskForCallReliabilityPermissions(BuildContext context) async {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return;

  final docRef = FirebaseFirestore.instance.collection('users').doc(user.uid);
  try {
    final doc = await docRef.get();
    final bool alreadyAsked =
        (doc.data()?['callReliabilityPermissionsAsked'] as bool?) ?? false;
    if (alreadyAsked) return;
  } catch (_) {
    // If we can't read the flag, fall through and ask anyway rather than
    // silently skipping a permission the call may actually need.
  }

  await _runCallReliabilityPermissionFlow(context);

  try {
    await docRef.set(
      {'callReliabilityPermissionsAsked': true},
      SetOptions(merge: true),
    );
  } catch (_) {
    // Non-critical - worst case, the flow just runs again next call.
  }
}

Future<void> _runCallReliabilityPermissionFlow(BuildContext context) async {
  try {
    final PermissionStatus status =
        await Permission.ignoreBatteryOptimizations.status;
    if (status.isGranted) return;
    if (!context.mounted) return;

    final bool? proceed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text(
          'Keep calls and messages reliable',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: const Text(
          "Some phones pause apps running in the background to save "
          "battery. So incoming calls and notifications always reach "
          "you - even when Fly isn't open - please allow Fly to run "
          "in the background.",
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Not now', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Allow',
                style: TextStyle(
                    color: Colors.redAccent, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (proceed == true) {
      // Opens Android's own system dialog for this specific permission -
      // same one-tap flow WhatsApp uses, no manual Settings navigation.
      await Permission.ignoreBatteryOptimizations.request();
    }

    // A third, separate permission ("draw over other apps" - MIUI calls
    // it "Display pop-up windows while running in the background") that
    // some phones require before a full-screen incoming-call notice can
    // actually pop up over the lock screen / other apps, even once
    // battery optimization and autostart are already sorted. Without
    // it, the push still arrives and the app still runs in the
    // background, but the call screen itself never becomes visible.
    await _maybeAskForOverlayPermission(context);

    // Android 14+ specifically: full-screen incoming-call notices need
    // their own separate permission here too - it's granted by default
    // only to apps the OS recognizes as calling/alarm apps, which a
    // sideloaded app like Fly isn't automatically classified as. This
    // is on top of, not instead of, the overlay permission above - both
    // are needed for the call screen to actually appear.
    await _maybeAskForFullScreenIntentPermission(context);

    // Standard Android battery optimization covers most phones, but
    // Xiaomi/Oppo/Vivo/Huawei add their own separate "Autostart" /
    // "Auto-launch" toggle on top of it, outside the standard Android
    // permission system entirely - there's no unified API for this
    // across manufacturers, which is why even WhatsApp/Messenger link
    // straight to each brand's own settings screen for it instead of
    // trying to request it like a normal permission.
    await _maybeOfferAutostartSettings(context);
  } catch (_) {
    // Non-critical - worst case, the user just doesn't get asked and
    // can still turn it on manually from the phone's Settings.
  }
}

// "Draw over other apps" (SYSTEM_ALERT_WINDOW) - the permission that
// actually lets a full-screen incoming-call notice pop up over the lock
// screen / whatever else is on screen. On plain Android this is usually
// pre-granted for apps installed normally, but MIUI in particular ships
// it off by default under the name "Display pop-up windows while
// running in the background", which silently blocks the call screen
// from appearing at all even once battery optimization and autostart
// are both already sorted.
Future<void> _maybeAskForOverlayPermission(BuildContext context) async {
  final PermissionStatus status = await Permission.systemAlertWindow.status;
  if (status.isGranted) return;
  if (!context.mounted) return;

  final bool? proceed = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF1E1E1E),
      title: const Text(
        'One more permission for incoming calls',
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
      ),
      content: const Text(
        "So the incoming-call screen can actually pop up over your "
        "lock screen (some phones call this \"display pop-up windows "
        "while running in the background\"), please allow it on the "
        "next screen.",
        style: TextStyle(color: Colors.white70),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Not now', style: TextStyle(color: Colors.grey)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Allow',
              style: TextStyle(
                  color: Colors.redAccent, fontWeight: FontWeight.bold)),
        ),
      ],
    ),
  );
  if (proceed == true) {
    await Permission.systemAlertWindow.request();
  }
}

// Android 14 (API 34) made full-screen call/alarm notifications a
// "special app access" permission that's off by default for any app
// the OS doesn't already recognize as a phone/dialer or alarm app -
// which a sideloaded app like Fly never is. There's no in-app system
// dialog for this one (unlike battery optimization) - it can only be
// granted from its own Settings page, which this opens directly via
// Android's own intent for it.
Future<void> _maybeAskForFullScreenIntentPermission(
    BuildContext context) async {
  try {
    final AndroidDeviceInfo info = await DeviceInfoPlugin().androidInfo;
    if (info.version.sdkInt < 34) return; // only exists on Android 14+
  } catch (_) {
    return;
  }
  if (!context.mounted) return;

  final bool? proceed = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF1E1E1E),
      title: const Text(
        'Allow full-screen incoming calls',
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
      ),
      content: const Text(
        "Your phone's version of Android added a setting specifically "
        "for apps showing a full-screen call notice. On the next "
        'screen, please turn this on for Fly so incoming calls can '
        'appear over your lock screen.',
        style: TextStyle(color: Colors.white70),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Not now', style: TextStyle(color: Colors.grey)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Open settings',
              style: TextStyle(
                  color: Colors.redAccent, fontWeight: FontWeight.bold)),
        ),
      ],
    ),
  );
  if (proceed != true) return;

  try {
    final intent = AndroidIntent(
      action: 'android.settings.MANAGE_APP_USE_FULL_SCREEN_INTENT',
      data: 'package:com.aungdev.fly',
    );
    await intent.launch();
  } catch (_) {
    // Older/unusual builds of Android 14 that don't expose this exact
    // settings page - nothing more to do automatically.
  }
}

// Deep-links straight to the manufacturer's own autostart/background
// permission screen, on the handful of Android skins known to need one -
// Xiaomi (MIUI), Oppo (ColorOS), Vivo (FuntouchOS), and Huawei/Honor
// (EMUI/MagicUI). Every entry is a native activity component that
// varies by ROM version, so this is best-effort by nature: on models/
// versions where the component doesn't match, the launch just silently
// fails and the user can still find the same toggle manually.
Future<void> _maybeOfferAutostartSettings(BuildContext context) async {
  late String manufacturer;
  try {
    final info = await DeviceInfoPlugin().androidInfo;
    manufacturer = info.manufacturer.toLowerCase();
  } catch (_) {
    return;
  }

  const Map<String, Map<String, String>> kAutostartActivities = {
    'xiaomi': {
      'pkg': 'com.miui.securitycenter',
      'cls': 'com.miui.permcenter.autostart.AutoStartManagementActivity',
    },
    'redmi': {
      'pkg': 'com.miui.securitycenter',
      'cls': 'com.miui.permcenter.autostart.AutoStartManagementActivity',
    },
    'oppo': {
      'pkg': 'com.coloros.safecenter',
      'cls': 'com.coloros.safecenter.permission.startup.StartupAppListActivity',
    },
    'vivo': {
      'pkg': 'com.vivo.permissionmanager',
      'cls': 'com.vivo.permissionmanager.activity.BgStartUpManagerActivity',
    },
    'huawei': {
      'pkg': 'com.huawei.systemmanager',
      'cls':
          'com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity',
    },
    'honor': {
      'pkg': 'com.huawei.systemmanager',
      'cls':
          'com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity',
    },
  };

  String? matchedBrand;
  for (final brand in kAutostartActivities.keys) {
    if (manufacturer.contains(brand)) {
      matchedBrand = brand;
      break;
    }
  }
  if (matchedBrand == null) return;
  if (!context.mounted) return;

  final String displayName =
      matchedBrand[0].toUpperCase() + matchedBrand.substring(1);
  final bool? proceed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF1E1E1E),
      title: Text(
        'One more step for $displayName phones',
        style:
            const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
      ),
      content: Text(
        "$displayName phones have their own separate \"Autostart\" "
        "switch. Please turn it on for Fly on the next screen, so "
        "calls keep coming through even when the app isn't open.",
        style: const TextStyle(color: Colors.white70),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Skip', style: TextStyle(color: Colors.grey)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Open settings',
              style: TextStyle(
                  color: Colors.redAccent, fontWeight: FontWeight.bold)),
        ),
      ],
    ),
  );
  if (proceed != true) return;

  try {
    final info = kAutostartActivities[matchedBrand]!;
    final intent = AndroidIntent(
      action: 'android.intent.action.MAIN',
      package: info['pkg'],
      componentName: info['cls'],
    );
    await intent.launch();
  } catch (_) {
    // This exact screen isn't reachable on this ROM version - nothing
    // more can be done automatically.
  }
}
