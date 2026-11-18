/* eslint-disable @typescript-eslint/no-var-requires */
/* eslint-disable no-console */
const Client = require('ssh2-sftp-client');
require('dotenv').config();

async function uploadFiles() {
  const sftp = new Client();

  try {
    await sftp.connect({
      host: process.env.SFTP_ROUTER,
      port: Number.parseInt(process.env.SFTP_PORT, 10) || 22,
      username: process.env.SFTP_USERNAME,
      password: process.env.SFTP_PASSWORD,
      readyTimeout: 3000
    });

    console.log('Connected via SFTP.');

    // Own tree /jffs/addons/ssurf — never official /jffs/addons/stealthsurf
    await sftp.mkdir('/jffs/addons/ssurf', true);
    await sftp.mkdir('/jffs/scripts', true);

    // Upload files
    await sftp.fastPut('dist/index.asp', '/jffs/addons/ssurf/index.asp');
    await sftp.fastPut('dist/app.js', '/jffs/addons/ssurf/app.js');
    await sftp.fastPut('dist/stealthsurf', '/jffs/scripts/ssurf');
    await sftp.fastPut('tools/adsblock/adsblock.sh', '/jffs/addons/ssurf/adsblock');

    // Set executable permissions
    await sftp.chmod('/jffs/scripts/ssurf', '755');
    await sftp.chmod('/jffs/addons/ssurf/adsblock', '755');

    console.log('Files uploaded and permissions set successfully.');
  } catch (err) {
    console.error('Error uploading files via SFTP:', err);
  } finally {
    sftp.end();
  }
}

uploadFiles();
