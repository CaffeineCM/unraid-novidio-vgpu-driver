<?PHP
#########################################################
#                                                       #
# CA Config Editor copyright 2017-2019, Andrew Zawadzki #
#                                                       #
#########################################################

$plugin = "novidio-vgpu-driver";
$docroot = $docroot ?: $_SERVER['DOCUMENT_ROOT'] ?: '/usr/local/emhttp';
$translations = file_exists("$docroot/webGui/include/Translations.php");
if ($translations) {
	// add translations
	$_SERVER['REQUEST_URI'] = 'configedit';
	require_once "$docroot/webGui/include/Translations.php";
} else {
	// legacy support (without javascript)
	$noscript = true;
	require_once "$docroot/plugins/$plugin/include/Legacy.php";
}

function readCFGfile($filename) {
  $data['contents'] = @file_get_contents($filename);
  if ($data['contents'] === false) {
    $data['error'] = "true";
  }
  $data['format'] = (strpos($data['contents'],"\r\n")) ? "dos" : "linux";
  $data['contents'] = str_replace("\r","",$data['contents']);
  return $data;
}

function jsonResponse($payload, $statusCode = 200) {
  http_response_code($statusCode);
  header('Content-Type: application/json');
  echo json_encode($payload);
  exit;
}

switch ($_POST['action']) {
  case 'edit':
    $filename = urldecode($_POST['filename']);
    echo json_encode(readCFGfile($filename));
    break;
  case 'save':
    $filedata = $_POST['filedata'];
    $backupContents = file_get_contents($filedata['filename']);
    file_put_contents("{$filedata['filename']}.bak",$backupContents);
    if ( $filedata['format'] == "true" ) {
      $filedata['contents'] = str_replace("\n","\r\n",$filedata['contents']);
    }
    file_put_contents($filedata['filename'],$filedata['contents']);
    echo "ok";
    break;
  case 'getBackup':
    $filename = urldecode($_POST['filename']);
    if (is_file("$filename.bak") ) {
      echo file_get_contents("$filename.bak");
    } else {
      echo _("No Backup File Found");
    }
    break;
  case 'upload_driver':
    if (!isset($_FILES['driver_package'])) {
      jsonResponse(['success' => false, 'message' => 'No upload payload received.'], 400);
    }

    $upload = $_FILES['driver_package'];
    if (($upload['error'] ?? UPLOAD_ERR_NO_FILE) !== UPLOAD_ERR_OK) {
      jsonResponse(['success' => false, 'message' => 'Upload failed before validation.'], 400);
    }

    $originalName = basename($upload['name']);
    $tmpUpload = tempnam(sys_get_temp_dir(), 'novidio-upload-');
    if ($tmpUpload === false) {
      jsonResponse(['success' => false, 'message' => 'Unable to allocate temporary upload storage.'], 500);
    }

    if (!move_uploaded_file($upload['tmp_name'], $tmpUpload)) {
      @unlink($tmpUpload);
      jsonResponse(['success' => false, 'message' => 'Unable to persist the uploaded file.'], 500);
    }

    $driverHelper = '/usr/local/emhttp/plugins/novidio-vgpu-driver/include/driver.sh';
    $command = escapeshellcmd($driverHelper).' import_upload '.escapeshellarg($tmpUpload).' '.escapeshellarg($originalName).' 2>&1';
    $output = [];
    $status = 0;
    exec($command, $output, $status);
    @unlink($tmpUpload);

    if ($status !== 0) {
      jsonResponse([
        'success' => false,
        'message' => trim(implode("\n", $output)) ?: 'Upload validation failed.',
      ], 400);
    }

    shell_exec('/usr/local/emhttp/plugins/novidio-vgpu-driver/include/exec.sh update');

    jsonResponse([
      'success' => true,
      'message' => trim(implode("\n", $output)) ?: 'Driver uploaded successfully.',
    ]);
    break;
}
?>
