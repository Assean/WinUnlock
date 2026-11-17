import asyncio
import time
import hmac
import hashlib
import logging
from bleak import BleakScanner, BleakClient

logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(message)s")
logger = logging.getLogger("WinUnlock")

SERVICE_UUID      = "a1b2c3d4-e5f6-4789-8012-3456789abcde"
TRIGGER_CHAR_UUID = "a1b2c3d4-e5f6-4789-8012-3456789abcdf"
TOKEN_CHAR_UUID   = "a1b2c3d4-e5f6-4789-8012-3456789abce0"
SECRET_KEY        = b"MySuperSecretUnlockKey_2026"

RSSI_THRESHOLD    = -58
COOLDOWN_SECONDS  = 12

last_trigger_time = 0.0
is_connecting     = False
target_queue      = asyncio.Queue()

def verify_token(payload_str: str) -> bool:
    try:
        ts_str, sig_hex = payload_str.strip().split("|")
        ts = int(ts_str)
        if abs(time.time() - ts) > 30:
            logger.warning("⚠️ 簽章已過期")
            return False
        expected_sig = hmac.new(SECRET_KEY, ts_str.encode("utf-8"), hashlib.sha256).hexdigest()
        return hmac.compare_digest(expected_sig, sig_hex)
    except Exception as e:
        logger.error(f"驗證格式錯誤: {e}")
        return False

async def interact_with_iphone(device):
    global is_connecting, last_trigger_time
    is_connecting = True
    unlock_event = asyncio.Event()

    def notification_handler(sender, data: bytearray):
        msg = data.decode("utf-8", errors="ignore")
        logger.info(f"📩 收到 iPhone 回傳簽章: {msg}")
        if verify_token(msg):
            logger.info("🔓 [解鎖執行] 驗證完全通過！準備解鎖 Windows 螢幕...")
            unlock_event.set()
        else:
            logger.error("❌ 簽章驗證失敗，拒絕解鎖！")

    try:
        logger.info(f"📡 偵測到 iPhone 靠近，建立無快取連線 ({device.address})...")
        async with BleakClient(device, timeout=15.0, winrt={"use_cached_services": False}) as client:
            await asyncio.sleep(0.5)
            found_services = [s.uuid.lower() for s in client.services]
            if SERVICE_UUID not in found_services:
                logger.warning(f"⚠️ 尚未讀到 WinUnlock 服務，目前可見服務: {found_services}")
                return

            await client.start_notify(TOKEN_CHAR_UUID, notification_handler)
            await asyncio.sleep(0.2)
            await client.write_gatt_char(TRIGGER_CHAR_UUID, b"SHOW_POPUP", response=True)
            logger.info("📱 已發送解鎖提示至 iPhone，等待點擊解鎖 (最多 20 秒)...")

            try:
                await asyncio.wait_for(unlock_event.wait(), timeout=20.0)
            except asyncio.TimeoutError:
                logger.info("⌛ 等待超時，使用者未點擊解鎖。")

            try:
                await client.stop_notify(TOKEN_CHAR_UUID)
            except Exception:
                pass
    except Exception as e:
        logger.warning(f"連線中斷或重試中: {e}")
    finally:
        last_trigger_time = time.time()
        is_connecting = False

async def main():
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
    logger.info(f"🚀 WinUnlock 掃描服務已啟動 (觸發門檻: RSSI >= {RSSI_THRESHOLD} dBm)")

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
