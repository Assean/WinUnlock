import asyncio
import ctypes
import hmac
import hashlib
import time
import logging
from bleak import BleakScanner, BleakClient

logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(message)s")
logger = logging.getLogger("WinUnlockAgent")

# 雙端約定的專屬 UUID 與共享密鑰（必須與 iOS 端完全一致）
SERVICE_UUID      = "a1b2c3d4-e5f6-4789-8012-3456789abcde"
TRIGGER_CHAR_UUID = "a1b2c3d4-e5f6-4789-8012-3456789abcdf"
TOKEN_CHAR_UUID   = "a1b2c3d4-e5f6-4789-8012-3456789abce0"
SECRET_KEY        = b"MySuperSecretUnlockKey_2026"

# 距離與防重複觸發參數
RSSI_THRESHOLD    = -55   # 訊號大於等於 -55 dBm 視為靠近筆電
COOLDOWN_SECONDS  = 15    # 每次觸發後的冷卻秒數

last_trigger_time = 0.0
is_connecting = False

def verify_hmac_token(payload: str) -> bool:
    try:
        ts_str, signature = payload.strip().split("|")
        ts = int(ts_str)
        if abs(time.time() - ts) > 5:
            logger.warning(f"❌ 時間戳記過期 (誤差 {abs(time.time() - ts):.1f} 秒)")
            return False
        expected_sig = hmac.new(SECRET_KEY, ts_str.encode("utf-8"), hashlib.sha256).hexdigest()
        return hmac.compare_digest(expected_sig, signature)
    except Exception as e:
        logger.warning(f"❌ 簽章格式錯誤: {e}")
        return False

def execute_windows_unlock():
    logger.info("🔓 [解鎖執行] 驗證完全通過！正在傳送解鎖指令至系統安全層...")
    ctypes.windll.user32.mouse_event(0x0001, 1, 0, 0, 0)

async def interact_with_iphone(device):
    global is_connecting, last_trigger_time
    is_connecting = True
    unlock_event = asyncio.Event()

    def on_token_notify(sender, data: bytearray):
        payload = data.decode("utf-8", errors="ignore")
        logger.info(f"📩 收到 iPhone 回傳簽章: {payload}")
        if verify_hmac_token(payload):
            execute_windows_unlock()
            unlock_event.set()
        else:
            logger.error("⛔ 簽章驗證失敗，拒絕解鎖！")

    try:
        logger.info(f"📡 偵測到 iPhone 靠近，建立加密連線 ({device.address})...")
        async with BleakClient(device, timeout=8.0) as client:
            if not client.is_connected:
                return
            await client.start_notify(TOKEN_CHAR_UUID, on_token_notify)
            await client.write_gatt_char(TRIGGER_CHAR_UUID, b"SHOW_POPUP", response=True)
            logger.info("📱 已觸發 iPhone 彈出解鎖卡片，等待點擊「解鎖」(最多等待 12 秒)...")
            try:
                await asyncio.wait_for(unlock_event.wait(), timeout=12.0)
            except asyncio.TimeoutError:
                logger.info("⌛ 等待超時，使用者未點擊解鎖。")
            await client.stop_notify(TOKEN_CHAR_UUID)
    except Exception as e:
        logger.warning(f"連線中斷或未就緒: {e}")
    finally:
        last_trigger_time = time.time()
        is_connecting = False

async def main():
    logger.info(f"🚀 WinUnlock 掃描服務已啟動 (觸發門檻: RSSI >= {RSSI_THRESHOLD} dBm)")
    target_queue = asyncio.Queue()

    def detection_callback(device, adv_data):
        global last_trigger_time, is_connecting
        uuids = [u.lower() for u in adv_data.service_uuids]
        if SERVICE_UUID in uuids:
            rssi = adv_data.rssi
            if rssi is not None and rssi >= RSSI_THRESHOLD:
                now = time.time()
                if not is_connecting and (now - last_trigger_time) > COOLDOWN_SECONDS:
                    logger.info(f"✨ 距離達標！iPhone RSSI = {rssi} dBm")
                    if target_queue.empty():
                        target_queue.put_nowait(device)

    scanner = BleakScanner(detection_callback=detection_callback)
    await scanner.start()

    try:
        while True:
            device = await target_queue.get()
            await interact_with_iphone(device)
    except KeyboardInterrupt:
        logger.info("正在停止掃描服務...")
    finally:
        await scanner.stop()

if __name__ == "__main__":
    asyncio.run(main())
