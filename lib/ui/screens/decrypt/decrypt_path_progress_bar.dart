import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:secure_upload/data/utils.dart' as utils;
import 'package:secure_upload/ui/custom/progress_indicator.dart';
import 'package:secure_upload/data/isolate_messages.dart';
import 'package:secure_upload/backend/crypto/cryptapi/cryptapi.dart';
import 'dart:io';
import 'dart:isolate';
import 'dart:async';
import '../../../data/strings.dart';

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


class IsolateDownloadData {
  final String url;
  final String destination;

  IsolateDownloadData(this.url, this.destination);
}

class IsolateDecryptData {
  final String file;
  final String password;
  final String destinationFile;

  IsolateDecryptData(this.file, this.password, this.destinationFile);
}

class DecryptProgress extends StatefulWidget {
  final String url;
  final String password;

  DecryptProgress({@required this.url, @required this.password});

  _DecryptProgressState createState() =>
      _DecryptProgressState(url: url, password: password);
}

class _DecryptProgressState extends State<DecryptProgress> {
  final String url;
  final String password;

  Isolate _downloadIsolate;
  Isolate _decryptIsolate;
  double _progress = 0.0;
  String _progressString = "0%";

  String filename; // = 'secureUpload-'+Filecrypt.randomFilename();
  String path; // = (await getTemporaryDirectory()).path;
  String tmpDestination; // = path+'/'+filename;
  String persistentDestination;

  _DecryptProgressState({this.url, this.password}) {
    start();
  }

  void dispose(){
    _downloadIsolate.kill();
    super.dispose();
  }

  void start() async {
    ReceivePort receivePort= ReceivePort(); //port for this main isolate to receive messages.
    filename = 'secureUpload-'+Filecrypt.randomFilename();
    path = (await getTemporaryDirectory()).path;
    tmpDestination = path+'/'+filename;
    persistentDestination = (await getExternalStorageDirectory()).path+'/'+filename;
    _downloadIsolate = await Isolate.spawn(downloadFile, IsolateInitMessage<IsolateDownloadData>(receivePort.sendPort, IsolateDownloadData(url, tmpDestination)));
    //_isolate = await Isolate.spawn(runTimer, receivePort.sendPort);
    receivePort.listen((data) {
      _communicateDownload(data);
    });



    //TODO: delete tmp-file
    //File(tmpDestination).deleteSync();
  }

  void _communicateDownload(IsolateMessage<String, String> message) async {
    _updateProgress(message.progress);
    if(message.finished) {
      _downloadIsolate.kill();
      ReceivePort receivePort= ReceivePort();
      _decryptIsolate = await Isolate.spawn(decryptFile, IsolateInitMessage<IsolateDecryptData>(receivePort.sendPort, IsolateDecryptData(tmpDestination, password, persistentDestination)));
      receivePort.listen((data) {
        _communicateDecrypt(data);
      });
    }
  }

  void _communicateDecrypt(IsolateMessage<String, String> message) async {
    _updateProgress(message.progress);
    if(message.finished) {
      _decryptIsolate.kill();
      File(tmpDestination).deleteSync();
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

  static void downloadFile(IsolateInitMessage<IsolateDownloadData> message) async {
    String url = message.data.url;

    HttpClient client = HttpClient();
    var request = await  client.getUrl(Uri.parse(url));
    var response = await request.close();
    var tmpFile = message.data.destination;

    var file = File(tmpFile);
    //var sink = file.openWrite();
    var output = file.openSync(mode: FileMode.write);
    var allBytes = response.contentLength;//50000;//await response.length;
    var writtenBytes = 0;
    response.listen((List event) {
      var writtenBytesNew = writtenBytes+event.length;
      output.writeFromSync(event);
      //sink.add(event);
      if(writtenBytesNew % 1024 != writtenBytes % 1024) {
        message.sendPort.send(IsolateMessage<String, String>(writtenBytesNew/(2*allBytes), false, false, null, null));
      }
      writtenBytes = writtenBytesNew;
    }, onDone: () {
      //sink.close();
      output.closeSync();
      message.sendPort.send(IsolateMessage<String, String>(0.5, true, false, null, null));
    }, onError: (e) {
      //sink.close();
      output.closeSync();
    });
    //await Isolate.spawn(encrypt, IsolateInitMessage<IsolateEncryptInitData>(_receiveEncrypt.sendPort, IsolateEncryptInitData(file, _appDocDir)))
  }

  static void decryptFile(IsolateInitMessage<IsolateDecryptData> message) async {
    try {
      // check if libsodium is supported for platform
      if (!Libsodium.supported()) {
        throw FormatException("Libsodium not supported");
      }

      // start encryption
      File sourceFile = File(message.data.file);
      File targetFile = File(message.data.destinationFile);

      ProgressOject progress = ProgressOject(message.sendPort, 0.5, 1.0);
      Filecrypt encFile = Filecrypt(base64.decode(message.data.password));
      encFile.init(sourceFile, CryptoMode.dec);
      bool success = encFile.writeIntoFile(
          targetFile, callback: progress.progress);
      if (!success) {
        message.sendPort.send(IsolateMessage<String, String>(0.0, true, true, "Encryption failed", null));
      } else {
        message.sendPort.send(
            IsolateMessage<String, String>(0.0, true, false, null, null));
      }
    } catch (e){
      print(e.toString());
      message.sendPort.send(IsolateMessage<String, String>(0.0, true, true, "File error", null));
    }
  }


  // TODO start download and decryption
  static void runTimer(SendPort sendPort) {
    double progress = 0.0;
    Timer.periodic(new Duration(seconds: 1), (Timer t) {
      progress = progress + 0.1;
      sendPort.send(progress);
    });
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
