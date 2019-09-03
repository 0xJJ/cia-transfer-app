import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';
import 'package:secure_upload/data/constants.dart';
import 'package:secure_upload/data/utils.dart' as utils;
import 'package:secure_upload/data/isolate_messages.dart';
import 'package:secure_upload/data/isolate_storage.dart';
import 'package:secure_upload/ui/custom/progress_indicator.dart';
import 'package:secure_upload/ui/screens/encrypt/encrypt_path_final.dart';
import 'package:secure_upload/backend/cloud/cloudClient.dart';
import 'package:secure_upload/backend/storage/storage.dart';
import 'package:secure_upload/backend/storage/mobileStorage.dart';
import 'package:secure_upload/backend/crypto/cryptapi/cryptapi.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'dart:isolate';
import 'dart:convert';

class IsolateEncryptInitData {
  final String file;
  final Directory appDir;

  IsolateEncryptInitData(this.file, this.appDir);
}

class IsolateUploadInitData {
  final String file;
  final SendPort send;
  final CloudProvider cloudProvider;

  IsolateUploadInitData(this.file, this.send, this.cloudProvider);
}

class IsolateVoidFunctions {
  final IsolateCommunication comm;

  IsolateVoidFunctions(this.comm);

  openURL(String url){
    comm.send(IsolateRequest<String>("url.openURL", url));
  }
}

class ProgressOject {
  final SendPort sendPort;
  double _start;
  double _end;

  ProgressOject(this.sendPort, startValue, endValue){
    double checkStart = startValue;
    double checkEnd = endValue;
    if (checkStart < 0.0){
      checkStart = 0.0;
    }

    if (checkEnd > 1.0){
      checkEnd = 1.0;
    }

    if (checkStart >= checkEnd){
      checkStart = 0.0;
      checkEnd = 1.0;
    }

    _start = checkStart;
    _end = checkEnd;
  }

  void progress(int status, int all, bool finished) {
    double progress = _start + (status / all) * (_end - _start);

    if (progress >= 1.0 && !finished){
      progress = 0.99;
    }

    sendPort.send(IsolateMessage<String, String>(progress, false, false, null, null));
  }
}

class EncryptProgress extends StatefulWidget {
  final String file;
  final CloudProvider cloudProvider;

  EncryptProgress({@required this.file, @required this.cloudProvider});

  _EncryptProgressState createState() =>
      _EncryptProgressState(file: file, cloudProvider: cloudProvider);
}

class _EncryptProgressState extends State<EncryptProgress> {
  final String file;
  final CloudProvider cloudProvider;

  Isolate _isolateEncrypt;
  Isolate _isolateUpload;
  ReceivePort _receiveEncrypt = ReceivePort();
  ReceivePort _receiveUpload = ReceivePort();
  ReceivePort _receiveStorage = ReceivePort();
  Storage storage = MobileStorage();
  IsolateCommunicationHandler _handler;

  double _progress = 0.0;
  String _progressString = "0%";
  Directory _appDocDir;
  String _key = null;

  bool _encryptError = false;
  bool _uploadError = false;
  bool _uploadStarted = false;

  _EncryptProgressState({this.file, this.cloudProvider}) {
    startEncryptAndUpload();
  }

  void dispose(){
    _isolateEncrypt.kill(priority: Isolate.immediate);

    if (_uploadStarted){
      _isolateUpload.kill(priority: Isolate.immediate);
    }

    _receiveEncrypt.close();
    _receiveUpload.close();
    _receiveStorage.close();

    super.dispose();
  }

  void startEncryptAndUpload() async {
    _handler = IsolateCommunicationHandler(_receiveStorage, _handleRequest);

    _appDocDir = await getApplicationDocumentsDirectory();
    _isolateEncrypt = await Isolate.spawn(encrypt, IsolateInitMessage<IsolateEncryptInitData>(_receiveEncrypt.sendPort, IsolateEncryptInitData(file, _appDocDir)));
    _receiveEncrypt.listen((data) {
      _communicateEncrypt(data);
    });
  }

  void _communicateEncrypt(IsolateMessage<String, String> message) async {
    if (message.error){
      // handle error
      _encryptError = true;
    }

    if (!_encryptError) {
      _updateProgress(message.progress);

      if (message.finished) {
        _isolateEncrypt.kill();
        _key = message.data;
        _isolateUpload = await Isolate.spawn(upload,
            IsolateInitMessage<IsolateUploadInitData>(
                _receiveUpload.sendPort, IsolateUploadInitData(_appDocDir.path + "/" + Consts.encryptTargetFile, _receiveStorage.sendPort, cloudProvider)));
        _uploadStarted = true;
        _handler.start();
        _receiveUpload.listen((data) {
          _communicateUpload(data);
        });
      }
    }
  }

  void _handleRequest(IsolateRequest request, IsolateCommunicationHandler handler) async {
    switch (request.method){
      case ".":
        handler.setSend(request.data);
        break;
      case "storage.get":
        String value = await storage.get(request.data);
        handler.send(IsolateResponse<String>(value));
        break;
      case "storage.set":
        List<String> data = request.data;
        storage.set(data[0], data[1]);
        break;
      case "url.openURL":
        utils.openURL(request.data);
        break;
      default:
        throw FormatException("Unknown method ${request.method}");
    }
  }

  void _communicateUpload(IsolateMessage<String, String> message){
    if (message.error){
      _uploadError = true;
    }

    if (!_uploadError){
      _updateProgress(message.progress);

      if (message.finished){
        var url = message.data;
        _isolateUpload.kill();

        Navigator.push(
            context,
            MaterialPageRoute(
                builder: (context) =>
                    FinalEncrypt(
                        url,
                        _key)));
      }
    }
  }

  void _updateProgress(double progress){
    setState(() {
      if (progress > _progress){
        _progress = progress;
      }

      if (_progress > 1.0){
        _progress = 1.0;
      }

        _progressString = "${(_progress * 100).toInt()}%";
    });
  }

  static void encrypt(IsolateInitMessage<IsolateEncryptInitData> message) async {
    Filecrypt encFile = Filecrypt();

    try {
      // check if libsodium is supported for platform
      if (!Libsodium.supported()) {
        throw FormatException("Libsodium not supported");
      }

      // start encryption
      File sourceFile = File(message.data.file);
      File targetFile = File(
          message.data.appDir.path + "/" + Consts.encryptTargetFile);

      ProgressOject progress = ProgressOject(message.sendPort, 0.0, 0.5);
      encFile.init(sourceFile, CryptoMode.enc);
      bool success = encFile.writeIntoFile(
          targetFile, callback: progress.progress);
      var key = base64.encode(encFile.getKey());
      encFile.clear();
      sourceFile.deleteSync();
      print("finished");

      if (!success) {
        message.sendPort.send(IsolateMessage<String, String>(0.0, true, true, "Encryption failed", null));
      } else {
        message.sendPort.send(
            IsolateMessage<String, String>(0.0, true, false, null, key));

        key = "";
      }
    } catch (e){
      print(e.toString());
      encFile.clear();
      message.sendPort.send(IsolateMessage<String, String>(0.0, true, true, "File error", null));
    }
  }

  // TODO implement upload
  static void upload(IsolateInitMessage<IsolateUploadInitData> message) async {
    File targetFile = File(message.data.file);
    IsolateCommunication comm = IsolateCommunication(message.data.send);
    Storage storage = IsolateStorage(comm);
    IsolateVoidFunctions voidFunctions = IsolateVoidFunctions(comm);
    // TODO remove it
    // TODO create ProcessObject for updating CircleProcessbar
    //Map<PermissionGroup, PermissionStatus> permissions = await PermissionHandler().requestPermissions([PermissionGroup.storage]);
    CloudClient client = await CloudClientFactory.create(message.data.cloudProvider, storage);
    if(!(await client.hasCredentials())) {
      await client.authenticate(voidFunctions.openURL);
    }

    var fileID = await client.createFile(Filecrypt.randomFilename(), targetFile);
    await client.setAccessibility(fileID, true);
    var url = await client.getURL(fileID);
    targetFile.deleteSync();
    message.sendPort.send(IsolateMessage<String, String>(1.0, true, false, null, url));
  }

  Widget build(BuildContext context) {
    return WillPopScope(
        //onWillPop: () async => false,
        child: Container(
          color: Theme.of(context).colorScheme.background,
          child: CircularPercentIndicator(
            progressColor: Theme.of(context).colorScheme.primary,
            radius: utils.screenWidth(context) / 2,
            animation: true,
            animateFromLastPercent: true,
            lineWidth: 5.0,
            percent: _progress,
            center: Text(_progressString),
      ),
    ));
  }
}
