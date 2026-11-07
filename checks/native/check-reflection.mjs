import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

// Inspect the final arm64 executable, after stripping. A nonempty reflstr
// section alone is insufficient: build 39 had one but no class field names.
export function checkReflection(binary) {
  function require(condition, message) {
    if (!condition) throw new Error(message);
  }
  function range(offset, length) {
    require(offset >= 0 && length >= 0 && offset + length <= binary.length,
      'Truncated or invalid Mach-O metadata');
  }
  range(0, 32);
  require(binary.readUInt32LE(0) === 0xfeedfacf &&
    binary.readUInt32LE(4) === 0x0100000c, 'Expected a thin arm64 Mach-O executable');
  let command = 32;
  let fields = 0;
  let missing = 0;
  for (let i = 0; i < binary.readUInt32LE(16); i++) {
    range(command, 8);
    const size = binary.readUInt32LE(command + 4);
    require(size >= 8, 'Invalid Mach-O load command');
    range(command, size);
    if (binary.readUInt32LE(command) === 0x19) {
      require(size >= 72, 'Invalid segment command');
      const sections = binary.readUInt32LE(command + 64);
      require(72 + sections * 80 <= size, 'Invalid section table');
      for (let j = 0; j < sections; j++) {
        const section = command + 72 + j * 80;
        const name = binary.toString('ascii', section, section + 16).replace(/\0.*$/, '');
        if (name !== '__swift5_fieldmd') continue;
        let cursor = binary.readUInt32LE(section + 48);
        const length = Number(binary.readBigUInt64LE(section + 40));
        range(cursor, length);
        const end = cursor + length;
        while (cursor < end) {
          require(cursor + 16 <= end, 'Truncated field descriptor');
          const kind = binary.readUInt16LE(cursor + 8);
          const stride = binary.readUInt16LE(cursor + 10);
          const count = binary.readUInt32LE(cursor + 12);
          require(stride >= 12 && cursor + 16 + count * stride <= end,
            'Invalid field records');
          // Class descriptors are reflected by Combine.ObservableObject.
          if (kind === 1) {
            for (let k = 0; k < count; k++) {
              fields++;
              const pointer = cursor + 16 + k * stride + 8;
              const relative = binary.readInt32LE(pointer);
              if (relative === 0) { missing++; continue; }
              const address = pointer + relative;
              range(address, 1);
              require(binary[address] !== 0 && binary.indexOf(0, address) !== -1,
                'Invalid reflection field name');
            }
          }
          cursor += 16 + count * stride;
        }
      }
    }
    command += size;
  }
  require(fields > 0, 'No Swift class fields found; cannot verify observation metadata');
  require(missing === 0,
    `${missing}/${fields} Swift class fields have no names. iOS 16 Combine can crash at launch. Set SWIFT_REFLECTION_METADATA_LEVEL = all.`);
  return fields;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    if (!process.argv[2]) throw new Error('Usage: node check-reflection.mjs <arm64 executable>');
    console.log(`Reflection check passed: ${checkReflection(readFileSync(process.argv[2]))} named class fields.`);
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
