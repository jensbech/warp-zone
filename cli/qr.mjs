import qrcode from 'qrcode-terminal';

const url = process.argv[2];
if (!url) {
  console.error('usage: qr.mjs <url>');
  process.exit(1);
}
qrcode.generate(url, { small: true }, (code) => console.log(code));
