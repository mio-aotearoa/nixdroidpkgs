/*
 * AsteroidOSSync
 * Copyright (c) 2026 AsteroidOS
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <http://www.gnu.org/licenses/>.
 */

package org.asteroidos.sync.connectivity;

import android.app.BroadcastOptions;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Bundle;
import android.os.Process;
import android.os.SystemClock;
import android.util.Log;

import androidx.core.app.NotificationCompat;
import androidx.core.app.RemoteInput;

import org.asteroidos.sync.asteroid.IAsteroidDevice;
import org.asteroidos.sync.utils.AsteroidUUIDS;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Iterator;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/**
 * AppBridge v2 connectivity service for AsteroidOS (inspired by Wear OS
 * MessageClient, DataClient, CapabilityClient, and ChannelClient).
 *
 * Wire format:
 *   [0]     magic    = 0xA1
 *   [1]     version  = 0x02 (explicit version for future expansion)
 *   [2]     msgType  = 0x01 MESSAGE | 0x02 DATA_PUT | 0x03 DATA_DEL | 0x04 DATA_GET
 *                    | 0x05 CAP_QUERY | 0x06 CAP_RESP | 0x07 CHAN_DATA
 *                    | 0x08 ACK | 0x09 PING | 0x0A PONG | 0x0B..0xFF reserved
 *   [3]     flags    = bit0: ACK_REQ (0x01), bit1: FIN (0x02), bits2..7: reserved
 *   [4..5]  msgId    = uint16 big-endian
 *   [6]     seq      = chunk index (0 .. total-1)
 *   [7]     total    = chunk count (1 .. 32)
 *   [8]     appLen   = 0..64
 *   [...]   appId
 *   [...]   pathLen  = 0..128
 *   [...]   path
 *   [...]   payload
 */
public class AppBridgeService implements IConnectivityService {
    public static final String TAG = "AppBridgeService";

    public static final String PERMISSION_APP_BRIDGE = "org.asteroidos.sync.permission.APP_BRIDGE";
    public static final String ACTION_RECEIVE_FROM_WATCH = "org.asteroidos.sync.ACTION_RECEIVE_FROM_WATCH";
    public static final String ACTION_SEND_TO_WATCH = "org.asteroidos.sync.ACTION_SEND_TO_WATCH";
    public static final String EXTRA_APP_ID = "extra_app_id";
    public static final String EXTRA_ACTION = "extra_action";
    public static final String EXTRA_PAYLOAD = "extra_payload";
    public static final String EXTRA_MSG_TYPE = "extra_msg_type";

    private static final int MAGIC = 0xA1;
    private static final int VERSION = 0x02;
    private static final int HEADER_FIXED = 10;
    private static final int MAX_PACKET = 512;
    private static final int MAX_APP_LEN = 64;
    private static final int MAX_PATH_LEN = 128;
    private static final int MAX_CHUNKS = 32;
    private static final int CHUNK_SIZE = 384;
    private static final int MAX_PAYLOAD = MAX_CHUNKS * CHUNK_SIZE;

    public static final int MSG_MESSAGE = 0x01;
    public static final int MSG_DATA_PUT = 0x02;
    public static final int MSG_DATA_DEL = 0x03;
    public static final int MSG_DATA_GET = 0x04;
    public static final int MSG_CAP_QUERY = 0x05;
    public static final int MSG_CAP_RESP = 0x06;
    public static final int MSG_CHAN_DATA = 0x07;
    public static final int MSG_ACK = 0x08;
    public static final int MSG_PING = 0x09;
    public static final int MSG_PONG = 0x0A;

    private static final int FLAG_NONE = 0x00;
    private static final int FLAG_ACK_REQ = 0x01;
    private static final int FLAG_FIN = 0x02;

    private static final String CAMERA_PACKAGE = "app.grapheneos.camera";
    private static final String CAMERA_APP_ID = "org.asteroidos.camera";
    private static final String CAMERA_WIRE_APP_ID = "cam";

    private static final String KEYBOARD_APP_ID = "org.asteroidos.keyboard";
    private static final String KEYBOARD_WIRE_APP_ID = "kbd";

    private static final String VELA_APP_ID = "org.asteroidos.vela";
    private static final String VELA_WIRE_APP_ID = "vela";

    private static final String SYSTEM_APP_ID = "org.asteroidos.system";
    private static final String SYSTEM_WIRE_APP_ID = "sys";

    private static final int KEYBOARD_NOTIFICATION_ID = 0xA072;
    private static final String KEYBOARD_CHANNEL_ID = "asteroidos_keyboard_channel";
    private static final String ACTION_KEYBOARD_REPLY = "org.asteroidos.sync.KEYBOARD_INPUT_REPLY";
    private static final String EXTRA_KEYBOARD_TEXT = "extra_keyboard_text";

    private static final String PREFS_DATALAYER = "asteroidos_datalayer";

    private static final Set<String> WATCH_TO_PHONE_CAMERA_ACTIONS = new HashSet<>(Arrays.asList(
            "capture", "flip", "zoom_in", "zoom_out", "torch",
            "mode_photo", "mode_video", "timer_cycle", "status_query"));
    private static final Set<String> PHONE_TO_WATCH_CAMERA_ACTIONS = new HashSet<>(Arrays.asList(
            "ready", "paused", "photo_captured", "video_started", "video_stopped", "state_changed"));

    private static final class ReassemblyState {
        final int msgType;
        final String appId;
        final String path;
        final int total;
        final boolean ackRequested;
        final byte[][] chunks;
        final boolean[] seen;
        final long createdMs;
        int received = 0;

        ReassemblyState(int msgType, String appId, String path, int total, boolean ackRequested) {
            this.msgType = msgType;
            this.appId = appId;
            this.path = path;
            this.total = total;
            this.ackRequested = ackRequested;
            this.chunks = new byte[total][];
            this.seen = new boolean[total];
            this.createdMs = SystemClock.elapsedRealtime();
        }
    }

    private final Context mCtx;
    private final IAsteroidDevice mDevice;
    private final SharedPreferences mDataPrefs;
    private final Map<Integer, ReassemblyState> mReassembly = new HashMap<>();
    private int mNextMsgId = 1;
    private BroadcastReceiver mSendReceiver;
    private BroadcastReceiver mReplyReceiver;

    public AppBridgeService(Context ctx, IAsteroidDevice device) {
        this.mCtx = ctx;
        this.mDevice = device;
        this.mDataPrefs = ctx.getSharedPreferences(PREFS_DATALAYER, Context.MODE_PRIVATE);

        device.registerCallback(AsteroidUUIDS.APP_BRIDGE_TX_CHAR, this::handleAppBridgeData);
        registerSendReceiver();
        registerReplyReceiver();
    }

    private synchronized void registerSendReceiver() {
        if (mSendReceiver != null) return;
        mSendReceiver = new BroadcastReceiver() {
            @Override
            public void onReceive(Context context, Intent intent) {
                handleSendToWatchIntent(intent, this);
            }
        };
        IntentFilter filter = new IntentFilter(ACTION_SEND_TO_WATCH);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            mCtx.registerReceiver(mSendReceiver, filter, PERMISSION_APP_BRIDGE, null,
                    Context.RECEIVER_EXPORTED);
        } else {
            mCtx.registerReceiver(mSendReceiver, filter, PERMISSION_APP_BRIDGE, null);
        }
    }

    private synchronized void registerReplyReceiver() {
        if (mReplyReceiver != null) return;
        mReplyReceiver = new BroadcastReceiver() {
            @Override
            public void onReceive(Context context, Intent intent) {
                if (intent == null || !ACTION_KEYBOARD_REPLY.equals(intent.getAction())) return;
                Bundle results = RemoteInput.getResultsFromIntent(intent);
                if (results != null) {
                    CharSequence text = results.getCharSequence(EXTRA_KEYBOARD_TEXT);
                    if (text != null && text.length() > 0) {
                        sendFrames(MSG_MESSAGE, KEYBOARD_WIRE_APP_ID, "commit",
                                text.toString().getBytes(StandardCharsets.UTF_8), FLAG_NONE);
                    }
                }
                cancelKeyboardInputNotification();
            }
        };
        IntentFilter filter = new IntentFilter(ACTION_KEYBOARD_REPLY);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            mCtx.registerReceiver(mReplyReceiver, filter, Context.RECEIVER_NOT_EXPORTED);
        } else {
            mCtx.registerReceiver(mReplyReceiver, filter);
        }
    }

    private synchronized void unregisterSendReceiver() {
        if (mSendReceiver != null) {
            try {
                mCtx.unregisterReceiver(mSendReceiver);
            } catch (IllegalArgumentException e) {
                Log.w(TAG, "Failed to unregister send receiver", e);
            }
            mSendReceiver = null;
        }
    }

    private synchronized void unregisterReplyReceiver() {
        if (mReplyReceiver != null) {
            try {
                mCtx.unregisterReceiver(mReplyReceiver);
            } catch (IllegalArgumentException e) {
                Log.w(TAG, "Failed to unregister reply receiver", e);
            }
            mReplyReceiver = null;
        }
    }

    private boolean isPackageInstalled(String pkg) {
        try {
            mCtx.getPackageManager().getPackageInfo(pkg, 0);
            return true;
        } catch (PackageManager.NameNotFoundException e) {
            return false;
        }
    }

    private boolean isSentFromCameraApp(BroadcastReceiver receiver) {
        if (Build.VERSION.SDK_INT < 34) return false;
        int sentFromUid = getSentFromUid(receiver);
        if (sentFromUid == Process.INVALID_UID) return false;
        try {
            return mCtx.getPackageManager().getPackageUid(CAMERA_PACKAGE, 0) == sentFromUid;
        } catch (PackageManager.NameNotFoundException e) {
            return false;
        }
    }

    private static int getSentFromUid(BroadcastReceiver receiver) {
        try {
            return (Integer) BroadcastReceiver.class.getMethod("getSentFromUid").invoke(receiver);
        } catch (ReflectiveOperationException | RuntimeException e) {
            return Process.INVALID_UID;
        }
    }

    private static String normalizeAppId(String wireOrCanonical) {
        if (CAMERA_WIRE_APP_ID.equals(wireOrCanonical) || CAMERA_APP_ID.equals(wireOrCanonical)) return CAMERA_APP_ID;
        if (KEYBOARD_WIRE_APP_ID.equals(wireOrCanonical) || KEYBOARD_APP_ID.equals(wireOrCanonical)) return KEYBOARD_APP_ID;
        if (VELA_WIRE_APP_ID.equals(wireOrCanonical) || VELA_APP_ID.equals(wireOrCanonical)) return VELA_APP_ID;
        if (SYSTEM_WIRE_APP_ID.equals(wireOrCanonical) || SYSTEM_APP_ID.equals(wireOrCanonical)) return SYSTEM_APP_ID;
        if (wireOrCanonical != null && wireOrCanonical.startsWith("org.asteroidos.")
                && wireOrCanonical.length() <= MAX_APP_LEN) {
            return wireOrCanonical;
        }
        return null;
    }

    private static String compactAppId(String canonical) {
        if (CAMERA_APP_ID.equals(canonical)) return CAMERA_WIRE_APP_ID;
        if (KEYBOARD_APP_ID.equals(canonical)) return KEYBOARD_WIRE_APP_ID;
        if (VELA_APP_ID.equals(canonical)) return VELA_WIRE_APP_ID;
        if (SYSTEM_APP_ID.equals(canonical)) return SYSTEM_WIRE_APP_ID;
        return canonical;
    }

    private void showKeyboardInputNotification(String prompt) {
        NotificationManager nm = (NotificationManager) mCtx.getSystemService(Context.NOTIFICATION_SERVICE);
        if (nm == null) return;

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel channel = new NotificationChannel(
                    KEYBOARD_CHANNEL_ID,
                    "Smartwatch Keyboard",
                    NotificationManager.IMPORTANCE_HIGH
            );
            channel.setDescription("Direct text input for smartwatch keyboard");
            nm.createNotificationChannel(channel);
        }

        RemoteInput remoteInput = new RemoteInput.Builder(EXTRA_KEYBOARD_TEXT)
                .setLabel("Type on phone...")
                .build();

        Intent replyIntent = new Intent(ACTION_KEYBOARD_REPLY).setPackage(mCtx.getPackageName());
        int flags = PendingIntent.FLAG_UPDATE_CURRENT;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            flags |= PendingIntent.FLAG_MUTABLE;
        }
        PendingIntent replyPendingIntent = PendingIntent.getBroadcast(mCtx, 0, replyIntent, flags);

        NotificationCompat.Action replyAction =
                new NotificationCompat.Action.Builder(
                        android.R.drawable.ic_menu_send,
                        "Send to Watch",
                        replyPendingIntent
                )
                .addRemoteInput(remoteInput)
                .build();

        int icon = mCtx.getApplicationInfo().icon != 0 ? mCtx.getApplicationInfo().icon : android.R.drawable.ic_input_add;
        String content = (prompt != null && !prompt.isEmpty()) ? prompt : "Enter text on phone to send to watch";

        Notification notification = new NotificationCompat.Builder(mCtx, KEYBOARD_CHANNEL_ID)
                .setSmallIcon(icon)
                .setContentTitle("Smartwatch Text Input")
                .setContentText(content)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setDefaults(Notification.DEFAULT_ALL)
                .setAutoCancel(true)
                .addAction(replyAction)
                .build();

        nm.notify(KEYBOARD_NOTIFICATION_ID, notification);
    }

    private void cancelKeyboardInputNotification() {
        NotificationManager nm = (NotificationManager) mCtx.getSystemService(Context.NOTIFICATION_SERVICE);
        if (nm != null) {
            nm.cancel(KEYBOARD_NOTIFICATION_ID);
        }
    }

    private void pruneStaleReassemblies() {
        long now = SystemClock.elapsedRealtime();
        Iterator<Map.Entry<Integer, ReassemblyState>> it = mReassembly.entrySet().iterator();
        while (it.hasNext()) {
            if (now - it.next().getValue().createdMs > 10000L) {
                it.remove();
            }
        }
    }

    private void handleAppBridgeData(byte[] value) {
        if (value == null || value.length < HEADER_FIXED || value.length > MAX_PACKET) return;
        if ((value[0] & 0xFF) != MAGIC || (value[1] & 0xFF) != VERSION) {
            Log.w(TAG, "AppBridge: unsupported header");
            return;
        }

        int msgType = value[2] & 0xFF;
        int flags = value[3] & 0xFF;
        int msgId = ((value[4] & 0xFF) << 8) | (value[5] & 0xFF);
        int seq = value[6] & 0xFF;
        int total = value[7] & 0xFF;

        if (msgType == MSG_ACK) {
            return;
        }
        if (msgType == MSG_PING) {
            byte[] echo = Arrays.copyOfRange(value, HEADER_FIXED, value.length);
            sendControlFrame(MSG_PONG, msgId, echo);
            return;
        }
        if (msgType == MSG_PONG) {
            return;
        }

        if (total == 0 || total > MAX_CHUNKS || seq >= total) return;

        int offset = 8;
        int appLen = value[offset++] & 0xFF;
        if (appLen == 0 || appLen > MAX_APP_LEN || value.length < offset + appLen + 1) return;
        String rawApp = new String(value, offset, appLen, StandardCharsets.UTF_8);
        offset += appLen;

        int pathLen = value[offset++] & 0xFF;
        if (pathLen == 0 || pathLen > MAX_PATH_LEN || value.length < offset + pathLen) return;
        String path = new String(value, offset, pathLen, StandardCharsets.UTF_8);
        offset += pathLen;

        String appId = normalizeAppId(rawApp);
        if (appId == null) return;

        byte[] chunk = Arrays.copyOfRange(value, offset, value.length);

        if (total == 1) {
            if ((flags & FLAG_ACK_REQ) != 0) {
                sendControlFrame(MSG_ACK, msgId, new byte[0]);
            }
            dispatchDecoded(msgType, appId, path, chunk);
            return;
        }

        synchronized (mReassembly) {
            pruneStaleReassemblies();
            ReassemblyState st = mReassembly.get(msgId);
            if (st == null) {
                if (mReassembly.size() >= 8) return;
                st = new ReassemblyState(msgType, appId, path, total, (flags & FLAG_ACK_REQ) != 0);
                mReassembly.put(msgId, st);
            }
            if (st.total != total || st.msgType != msgType || !st.appId.equals(appId) || !st.path.equals(path)) {
                return;
            }
            if (!st.seen[seq]) {
                st.seen[seq] = true;
                st.chunks[seq] = chunk;
                st.received++;
            }
            if (st.received == st.total) {
                ByteArrayOutputStream bos = new ByteArrayOutputStream();
                for (byte[] c : st.chunks) {
                    if (c != null) bos.write(c, 0, c.length);
                }
                boolean needAck = st.ackRequested;
                mReassembly.remove(msgId);
                if (needAck) {
                    sendControlFrame(MSG_ACK, msgId, new byte[0]);
                }
                dispatchDecoded(msgType, appId, path, bos.toByteArray());
            }
        }
    }

    private void dispatchDecoded(int msgType, String appId, String path, byte[] payloadBytes) {
        if (payloadBytes.length > MAX_PAYLOAD) return;
        String payload = new String(payloadBytes, StandardCharsets.UTF_8);

        if (msgType == MSG_CAP_QUERY) {
            sendCapabilitiesResponse();
            return;
        }
        if (msgType == MSG_DATA_PUT) {
            mDataPrefs.edit().putString(appId + "|" + path, payload).apply();
            broadcastToAuthorizedApps(msgType, appId, path, payload, null);
            return;
        }
        if (msgType == MSG_DATA_DEL) {
            mDataPrefs.edit().remove(appId + "|" + path).apply();
            broadcastToAuthorizedApps(msgType, appId, path, "", null);
            return;
        }
        if (msgType == MSG_DATA_GET) {
            String key = appId + "|" + path;
            if (mDataPrefs.contains(key)) {
                String val = mDataPrefs.getString(key, "");
                sendFrames(MSG_DATA_PUT, compactAppId(appId), path,
                        val.getBytes(StandardCharsets.UTF_8), FLAG_NONE);
            }
            return;
        }
        if (msgType == MSG_CHAN_DATA) {
            broadcastToAuthorizedApps(msgType, appId, path, payload, null);
            return;
        }

        if (msgType != MSG_MESSAGE) return;

        if (KEYBOARD_APP_ID.equals(appId)) {
            if ("request_input".equals(path) || "open".equals(path)) {
                showKeyboardInputNotification(payload);
            } else if ("close".equals(path)) {
                cancelKeyboardInputNotification();
            }
            return;
        }

        if (CAMERA_APP_ID.equals(appId)) {
            if (!WATCH_TO_PHONE_CAMERA_ACTIONS.contains(path)) return;
            broadcastToAuthorizedApps(msgType, CAMERA_APP_ID, path, payload, CAMERA_PACKAGE);
            return;
        }

        broadcastToAuthorizedApps(msgType, appId, path, payload, null);
    }

    private void sendCapabilitiesResponse() {
        try {
            JSONArray caps = new JSONArray();
            caps.put("protocol_v2");
            caps.put("keyboard_input");
            caps.put("datalayer_v2");
            caps.put("channel_stream");
            caps.put("vela_interconnect");
            if (isPackageInstalled(CAMERA_PACKAGE)) {
                caps.put("camera_remote_v2");
            }
            JSONObject obj = new JSONObject();
            obj.put("version", VERSION);
            obj.put("capabilities", caps);
            sendFrames(MSG_CAP_RESP, SYSTEM_WIRE_APP_ID, "/capabilities",
                    obj.toString().getBytes(StandardCharsets.UTF_8), FLAG_NONE);
        } catch (JSONException e) {
            Log.w(TAG, "Failed to build capability response", e);
        }
    }

    private void broadcastToAuthorizedApps(int msgType, String appId, String path, String payload, String targetPkg) {
        Intent intent = new Intent(ACTION_RECEIVE_FROM_WATCH)
                .putExtra(EXTRA_MSG_TYPE, msgType)
                .putExtra(EXTRA_APP_ID, appId)
                .putExtra(EXTRA_ACTION, path)
                .putExtra(EXTRA_PAYLOAD, payload);
        if (targetPkg != null) {
            intent.setPackage(targetPkg);
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            Bundle options = BroadcastOptions.makeBasic()
                    .setShareIdentityEnabled(true)
                    .toBundle();
            mCtx.sendBroadcast(intent, PERMISSION_APP_BRIDGE, options);
        } else {
            mCtx.sendBroadcast(intent, PERMISSION_APP_BRIDGE);
        }
    }

    private void handleSendToWatchIntent(Intent intent, BroadcastReceiver receiver) {
        if (intent == null || !ACTION_SEND_TO_WATCH.equals(intent.getAction())) return;
        String rawAppId = intent.getStringExtra(EXTRA_APP_ID);
        String path = intent.getStringExtra(EXTRA_ACTION);
        String payload = intent.getStringExtra(EXTRA_PAYLOAD);
        int msgType = intent.getIntExtra(EXTRA_MSG_TYPE, MSG_MESSAGE);

        String appId = normalizeAppId(rawAppId);
        if (appId == null || path == null || path.isEmpty() || path.length() > MAX_PATH_LEN) return;

        if (CAMERA_APP_ID.equals(appId)) {
            if (!isSentFromCameraApp(receiver)) {
                Log.w(TAG, "AppBridge: dropping camera message not sent by " + CAMERA_PACKAGE);
                return;
            }
            if (msgType == MSG_MESSAGE && !PHONE_TO_WATCH_CAMERA_ACTIONS.contains(path)) return;
        }

        byte[] payloadBytes = payload != null ? payload.getBytes(StandardCharsets.UTF_8) : new byte[0];
        if (payloadBytes.length > MAX_PAYLOAD) return;

        if (msgType == MSG_DATA_PUT) {
            mDataPrefs.edit().putString(appId + "|" + path, payload != null ? payload : "").apply();
        } else if (msgType == MSG_DATA_DEL) {
            mDataPrefs.edit().remove(appId + "|" + path).apply();
        }

        int flags = (msgType == MSG_CHAN_DATA) ? (FLAG_ACK_REQ | FLAG_FIN) : FLAG_NONE;
        sendFrames(msgType, compactAppId(appId), path, payloadBytes, flags);
    }

    private synchronized void sendFrames(int msgType, String wireAppId, String path, byte[] payload, int flags) {
        byte[] appBytes = wireAppId.getBytes(StandardCharsets.UTF_8);
        byte[] pathBytes = path.getBytes(StandardCharsets.UTF_8);
        int headerOverhead = HEADER_FIXED + appBytes.length + pathBytes.length;
        int maxChunk = Math.min(CHUNK_SIZE, MAX_PACKET - headerOverhead);
        if (maxChunk <= 0) return;

        int total = Math.max(1, (payload.length + maxChunk - 1) / maxChunk);
        if (total > MAX_CHUNKS) return;

        int msgId = mNextMsgId++;
        if (mNextMsgId > 0xFFFF) mNextMsgId = 1;

        for (int seq = 0; seq < total; seq++) {
            int start = seq * maxChunk;
            int len = Math.min(maxChunk, Math.max(0, payload.length - start));
            int chunkFlags = (seq == total - 1) ? flags : (flags & ~FLAG_FIN);

            byte[] packet = new byte[headerOverhead + len];
            int idx = 0;
            packet[idx++] = (byte) MAGIC;
            packet[idx++] = (byte) VERSION;
            packet[idx++] = (byte) msgType;
            packet[idx++] = (byte) chunkFlags;
            packet[idx++] = (byte) ((msgId >> 8) & 0xFF);
            packet[idx++] = (byte) (msgId & 0xFF);
            packet[idx++] = (byte) seq;
            packet[idx++] = (byte) total;
            packet[idx++] = (byte) appBytes.length;
            System.arraycopy(appBytes, 0, packet, idx, appBytes.length);
            idx += appBytes.length;
            packet[idx++] = (byte) pathBytes.length;
            System.arraycopy(pathBytes, 0, packet, idx, pathBytes.length);
            idx += pathBytes.length;
            if (len > 0) {
                System.arraycopy(payload, start, packet, idx, len);
            }
            mDevice.send(AsteroidUUIDS.APP_BRIDGE_RX_CHAR, packet, this);
        }
    }

    private void sendControlFrame(int msgType, int msgId, byte[] payload) {
        int len = payload != null ? Math.min(payload.length, MAX_PACKET - HEADER_FIXED) : 0;
        byte[] packet = new byte[HEADER_FIXED + len];
        packet[0] = (byte) MAGIC;
        packet[1] = (byte) VERSION;
        packet[2] = (byte) msgType;
        packet[3] = (byte) FLAG_NONE;
        packet[4] = (byte) ((msgId >> 8) & 0xFF);
        packet[5] = (byte) (msgId & 0xFF);
        packet[6] = 0;
        packet[7] = 1;
        packet[8] = 0;
        packet[9] = 0;
        if (len > 0) {
            System.arraycopy(payload, 0, packet, HEADER_FIXED, len);
        }
        mDevice.send(AsteroidUUIDS.APP_BRIDGE_RX_CHAR, packet, this);
    }

    @Override
    public void sync() {
        registerSendReceiver();
        registerReplyReceiver();
    }

    @Override
    public void unsync() {
        cancelKeyboardInputNotification();
        unregisterSendReceiver();
        unregisterReplyReceiver();
    }

    @Override
    public HashMap<UUID, Direction> getCharacteristicUUIDs() {
        HashMap<UUID, Direction> chars = new HashMap<>();
        chars.put(AsteroidUUIDS.APP_BRIDGE_TX_CHAR, Direction.FROM_WATCH);
        chars.put(AsteroidUUIDS.APP_BRIDGE_RX_CHAR, Direction.TO_WATCH);
        return chars;
    }

    @Override
    public UUID getServiceUUID() {
        return AsteroidUUIDS.APP_BRIDGE_SERVICE_UUID;
    }
}
