import asyncio, uuid, time, hmac, hashlib, logging, socket, ctypes
from ctypes import wintypes
from pathlib import Path
from winrt.windows.devices.bluetooth import BluetoothError
from winrt.windows.devices.bluetooth.advertisement import BluetoothLEAdvertisementPublisher, BluetoothLEManufacturerData
from winrt.windows.devices.bluetooth.genericattributeprofile import GattServiceProvider, GattLocalCharacteristicParameters, GattCharacteristicProperties, GattProtectionLevel, GattServiceProviderAdvertisingParameters
from winrt.windows.storage.streams import DataReader, DataWriter

LOG_FILE = Path(__file__).parent / "server.log"
logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(message)s", handlers=[logging.StreamHandler(), logging.FileHandler(LOG_FILE, encoding="utf-8")])
logger = logging.getLogger("WinUnlockServer")

SERVICE_UUID, TOKEN_CHAR_UUID = "0000fff0-0000-1000-8000-00805f9b34fb", "0000fff1-0000-1000-8000-00805f9b34fb"
IBEACON_UUID, SECRET_KEY = "a1b2c3d4-e5f6-4789-8012-3456789abcde", b"MySuperSecretUnlockKey_2026"
last_unlock_ts = 0.0

user32 = ctypes.windll.user32
user32.OpenInputDesktop.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
user32.OpenInputDesktop.restype = wintypes.HANDLE
user32.CloseDesktop.argtypes = [wintypes.HANDLE]
user32.GetUserObjectInformationW.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(wintypes.DWORD)]

def is_windows_locked() -> bool:
    h_desk = user32.OpenInputDesktop(0, False, 0x0001)
    if not h_desk:
        return True
    try:
        name = ctypes.create_unicode_buffer(256)
        needed = wintypes.DWORD()
        if user32.GetUserObjectInformationW(h_desk, 2, name, ctypes.sizeof(name), ctypes.byref(needed)):
            return name.value.lower() != "default"
        return False
    finally:
        user32.CloseDesktop(h_desk)

def verify_token(payload_str: str) -> bool:
    try:
        ts_str, sig_hex = payload_str.strip().split("|")
        if abs(time.time() - int(ts_str)) > 30:
            return False
        exp = hmac.new(SECRET_KEY, ts_str.encode("utf-8"), hashlib.sha256).hexdigest()
        return hmac.compare_digest(exp, sig_hex)
    except Exception:
        return False

def trigger_winlogon_helper() -> str:
    try:
        ts_str = str(int(time.time()))
        sig = hmac.new(SECRET_KEY, ts_str.encode("utf-8"), hashlib.sha256).hexdigest()
        with socket.create_connection(("127.0.0.1", 58923), timeout=3.0) as s:
            s.sendall(f"UNLOCK|{ts_str}|{sig}".encode("utf-8"))
            return s.recv(256).decode("utf-8", errors="ignore")
    except Exception as e:
        return f"ERR:代理連線失敗({e})"

async def main():
    global last_unlock_ts
    loop = asyncio.get_running_loop()
    result = await GattServiceProvider.create_async(uuid.UUID(SERVICE_UUID))
    provider = result.service_provider
    char_params = GattLocalCharacteristicParameters()
    char_params.characteristic_properties = GattCharacteristicProperties.WRITE | GattCharacteristicProperties.WRITE_WITHOUT_RESPONSE
    char_params.write_protection_level = GattProtectionLevel.PLAIN
    char_res = await provider.service.create_characteristic_async(uuid.UUID(TOKEN_CHAR_UUID), char_params)
    token_char = char_res.characteristic

    async def handle_write(args, deferral):
        global last_unlock_ts
        try:
            req = await args.get_request_async()
            if not req:
                return
            reader = DataReader.from_buffer(req.value)
            msg = bytes([reader.read_byte() for _ in range(reader.unconsumed_buffer_length)]).decode("utf-8", errors="ignore")
            req.respond()
            if not is_windows_locked():
                return
            now = time.time()
            if now - last_unlock_ts < 10.0:
                return
            if verify_token(msg):
                last_unlock_ts = now
                res = await asyncio.to_thread(trigger_winlogon_helper)
                logger.info(f"🔓 [鎖屏觸發] 簽章通過 → 代理回報: {res}")
            else:
                logger.warning(f"⚠️簽章無效: {msg}")
        except Exception as e:
            logger.error(f"寫入異常: {e}")
        finally:
            deferral.complete()

    token_char.add_write_requested(lambda s, a: asyncio.run_coroutine_threadsafe(handle_write(a, a.get_deferral()), loop))
    adv = GattServiceProviderAdvertisingParameters()
    adv.is_discoverable = True
    adv.is_connectable = True

    writer = DataWriter()
    writer.write_bytes(b"\x02\x15" + uuid.UUID(IBEACON_UUID).bytes + b"\x00\x01\x00\x01\xc5")
    mfg = BluetoothLEManufacturerData()
    mfg.company_id = 0x004C
    mfg.data = writer.detach_buffer()
    pub = BluetoothLEAdvertisementPublisher()
    pub.advertisement.manufacturer_data.append(mfg)

    is_advertising = False
    logger.info("🛡️ 動態藍牙廣播服務已就緒（僅在螢幕鎖定時廣播）")
    try:
        while True:
            locked = is_windows_locked()
            if locked and not is_advertising:
                provider.start_advertising(adv)
                pub.start()
                is_advertising = True
                logger.info("🔒 偵測到螢幕鎖定 → 啟動雙引擎藍牙廣播")
            elif not locked and is_advertising:
                try:
                    pub.stop()
                except Exception:
                    pass
                try:
                    provider.stop_advertising()
                except Exception:
                    pass
                is_advertising = False
                logger.info("🔓 偵測到已進入桌面 → 自動暫停藍牙廣播")
            await asyncio.sleep(1)
    finally:
        if is_advertising:
            try:
                pub.stop()
                provider.stop_advertising()
            except Exception:
                pass

if __name__ == "__main__":
    asyncio.run(main())
