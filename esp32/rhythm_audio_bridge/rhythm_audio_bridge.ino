#include <Arduino.h>
#include <SPI.h>

// สำหรับ ESP32 DevKit รุ่นปกติ
constexpr int PIN_SCK   = 18;
constexpr int PIN_MISO  = 19;
constexpr int PIN_MOSI  = 23;
constexpr int PIN_CS    = 21;
constexpr int PIN_READY = 27;

// ต้องตรงกับ MATLAB และการตั้งค่าฝั่ง FPGA
constexpr uint32_t SERIAL_BAUD = 921600;
constexpr uint32_t SPI_HZ = 1000000;
constexpr uint32_t SAMPLE_RATE = 16000;
constexpr uint16_t SAMPLE_COUNT = 1024;

// 1 = ADC 12-bit unsigned เก็บในข้อมูล 16-bit
constexpr uint16_t SAMPLE_FORMAT = 1;

constexpr size_t PAYLOAD_BYTES = SAMPLE_COUNT * 2;

// FPGA ส่ง sequence 4 bytes ตามด้วยข้อมูลเสียง
// โปรโตคอล SPI นี้ยังไม่มี CRC จาก FPGA
constexpr size_t SPI_BYTES = 4 + PAYLOAD_BYTES;

static uint8_t txZeros[SPI_BYTES] = {};
static uint8_t fpgaBlock[SPI_BYTES];
static uint8_t header[16];

// เก็บจำนวนเต็ม 16-bit แบบ little-endian
void putLE16(uint8_t *dst, uint16_t value) {
  dst[0] = static_cast<uint8_t>(value);
  dst[1] = static_cast<uint8_t>(value >> 8);
}

// เก็บจำนวนเต็ม 32-bit แบบ little-endian
void putLE32(uint8_t *dst, uint32_t value) {
  for (int i = 0; i < 4; ++i) {
    dst[i] = static_cast<uint8_t>(value >> (8 * i));
  }
}

// CRC-32/ISO-HDLC
// เริ่มด้วย 0xFFFFFFFF และ XOR ปิดท้ายด้วย 0xFFFFFFFF
uint32_t crc32Update(
  uint32_t crc,
  const uint8_t *data,
  size_t length
) {
  for (size_t i = 0; i < length; ++i) {
    crc ^= data[i];

    for (int bit = 0; bit < 8; ++bit) {
      if (crc & 1u) {
        crc = (crc >> 1) ^ 0xEDB88320u;
      } else {
        crc >>= 1;
      }
    }
  }

  return crc;
}

// ส่งให้ครบ แม้ Serial.write() รับได้ครั้งละบางส่วน
void writeAll(const uint8_t *data, size_t size) {
  size_t sent = 0;

  while (sent < size) {
    size_t written = Serial.write(data + sent, size - sent);
    sent += written;

    if (written == 0) {
      // รอการส่ง UART เท่านั้น
      // FPGA เป็นผู้ควบคุมจังหวะ sampling
      delay(1);
    }
  }
}

void setup() {
  // CS เป็น HIGH เมื่อไม่ได้รับข้อมูล
  digitalWrite(PIN_CS, HIGH);
  pinMode(PIN_CS, OUTPUT);

  pinMode(PIN_READY, INPUT_PULLDOWN);

  Serial.begin(SERIAL_BAUD);
  SPI.begin(PIN_SCK, PIN_MISO, PIN_MOSI, PIN_CS);

  // แพ็กเก็ตที่มี CRC ใช้ magic "T3AC"
  header[0] = 'T';
  header[1] = '3';
  header[2] = 'A';
  header[3] = 'C';

  // SAMPLE_RATE เป็นข้อมูลประกอบแพ็กเก็ต
  // ไม่ได้ตั้ง sampling rate ของ FPGA
  putLE32(header + 4, SAMPLE_RATE);
  putLE16(header + 8, SAMPLE_COUNT);
  putLE16(header + 10, SAMPLE_FORMAT);
}

void loop() {
  // รอ FPGA เก็บครบ 1024 samples
  if (digitalRead(PIN_READY) == LOW) {
    delay(1);
    return;
  }

  // ESP32 เป็น SPI Master
  SPI.beginTransaction(
    SPISettings(SPI_HZ, MSBFIRST, SPI_MODE0)
  );

  digitalWrite(PIN_CS, LOW);

  // ให้ FPGA เตรียมข้อมูลบิตแรก
  delayMicroseconds(2);

  // รับ sequence 4 bytes + samples 2048 bytes
  SPI.transferBytes(txZeros, fpgaBlock, SPI_BYTES);

  digitalWrite(PIN_CS, HIGH);
  SPI.endTransaction();

  // ใช้ sequence ของ FPGA โดยตรง
  // ไม่สร้าง sequence ใหม่ที่ ESP32
  for (int i = 0; i < 4; ++i) {
    header[12 + i] = fpgaBlock[i];
  }

  // คำนวณ CRC ครอบคลุม header และข้อมูลเสียง
  uint32_t crc = 0xFFFFFFFFu;

  crc = crc32Update(
    crc,
    header,
    sizeof(header)
  );

  crc = crc32Update(
    crc,
    fpgaBlock + 4,
    PAYLOAD_BYTES
  );

  crc ^= 0xFFFFFFFFu;

  // ส่ง CRC เป็น 4 bytes แบบ little-endian
  uint8_t crcBytes[4];
  putLE32(crcBytes, crc);

  // แพ็กเก็ตรวม 2068 bytes:
  // header 16 + samples 2048 + CRC 4
  writeAll(header, sizeof(header));
  writeAll(fpgaBlock + 4, PAYLOAD_BYTES);
  writeAll(crcBytes, sizeof(crcBytes));

  // ห้ามใส่ Serial.print()/println() บนช่องข้อมูลนี้
}