import asyncio
import uuid
import hmac
import hashlib
import time
import logging

from winrt.windows.devices.bluetooth import BluetoothError
from winrt.windows.devices.bluetooth.genericattributeprofile import (
    GattServiceProvider,
    GattServiceProviderAdvertisingParameters,
    GattLocalCharacteristicParameters,
    GattCharacteristicProperties,
    GattProtectionLevel,
    GattWriteOption,
)
from winrt.windows.storage.streams import DataReader

logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(message)s")
logger = logging.getLogger("WinUnlock")

# 專屬服務與特徵值 UUID
SERVICE_UUID = "A1B2C3D4-E5F6-4789-8012-3456789ABCDE"
CHAR_UUID    = "A1B2C3D4-E5F6-4789-8012-3456789ABCDF"

# 預先共享密鑰
SECRET_KEY = b"MySuperSecretUnlockKey_2026"

def verify_token(payload: str) -> bool:
    """驗證格式: <unix_timestamp>|<hmac_sha256_hex>"""
    try:
        ts_str, signature = payload.strip().split("|")
        ts = int(ts_str)

        # 防重放攻擊：時間誤差限制 5 秒內
        if abs(time.time() - ts) > 5:
            logger.warning(f"驗證失敗：時間戳記過期 (誤差 {abs(time.time() - ts):.1f} 秒)")
            return False

        expected_sig = hmac.new(SECRET_KEY, ts_str.encode("utf-8"), hashlib.sha256).hexdigest()
        return hmac.compare_digest(expected_sig, signature)
    except Exception as e:
        logger.warning(f"封包格式錯誤: {e}")
        return False

async def handle_write_request(args):
    deferral = args.get_deferral()
    try:
        request = await args.get_request_async()
        reader = DataReader.from_buffer(request.value)
        raw_bytes = bytes([reader.read_byte() for _ in range(reader.unconsumed_buffer_length)])
        raw_text = raw_bytes.decode("utf-8", errors="ignore")

        logger.info(f"收到藍牙寫入封包: {raw_text}")

        if raw_text == "TEST_UNLOCK" or verify_token(raw_text):
            logger.info("✅ [驗證通過] 準備執行 Windows 鎖定畫面解鎖！")
        else:
            logger.error("❌ [驗證拒絕] 非法或過期的解鎖請求")

        if request.option == GattWriteOption.WRITE_WITH_RESPONSE:
            request.respond()
    except Exception as e:
        logger.error(f"處理寫入請求時發生錯誤: {e}")
    finally:
        deferral.complete()

async def main():
    loop = asyncio.get_running_loop()

    # 1. 建立 GATT 服務
    service_result = await GattServiceProvider.create_async(uuid.UUID(SERVICE_UUID))
    if service_result.error != BluetoothError.SUCCESS:
        logger.error(f"建立 GATT 服務失敗: {service_result.error}")
        return

    provider = service_result.service_provider

    # 2. 建立可寫入的特徵值
    char_params = GattLocalCharacteristicParameters()
    char_params.characteristic_properties = (
        GattCharacteristicProperties.WRITE | GattCharacteristicProperties.WRITE_WITHOUT_RESPONSE
    )
    char_params.write_protection_level = GattProtectionLevel.PLAIN

    char_result = await provider.service.create_characteristic_async(
        uuid.UUID(CHAR_UUID), char_params
    )
    if char_result.error != BluetoothError.SUCCESS:
        logger.error(f"建立特徵值失敗: {char_result.error}")
        return

    characteristic = char_result.characteristic

    # 3. 綁定寫入事件（將 WinRT 背景執行緒轉回 asyncio 事件迴圈）
    def on_write_requested(sender, args):
        loop.call_soon_threadsafe(lambda: asyncio.create_task(handle_write_request(args)))

    characteristic.add_write_requested(on_write_requested)

    # 4. 啟動可探索且可連線的 BLE 廣播
    adv_params = GattServiceProviderAdvertisingParameters()
    adv_params.is_discoverable = True
    adv_params.is_connectable = True
    provider.start_advertising(adv_params)

    logger.info(f"🚀 WinUnlock BLE 伺服器已啟動！廣播狀態: {provider.advertisement_status.name}")
    logger.info(f"服務 UUID: {SERVICE_UUID}")

    try:
        while True:
            await asyncio.sleep(1)
    except KeyboardInterrupt:
        provider.stop_advertising()
        logger.info("伺服器已停止。")

if __name__ == "__main__":
    asyncio.run(main())