import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'services/auth_controller.dart';
import 'services/auth_store.dart';
import 'services/chat_controller.dart';
import 'services/drive_controller.dart';
import 'services/voice_controller.dart';
import 'services/webrpc_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = await AuthStore.open();
  final webrpc = WebrpcService();
  final chat = ChatController(webrpc: webrpc);
  final drive = DriveController(webrpc: webrpc);
  chat.attachDrive(drive);
  final voice = VoiceController(webrpc: webrpc, chat: chat);
  chat.attachVoice(voice);
  final auth = AuthController(
    store: store,
    webrpc: webrpc,
    chat: chat,
    drive: drive,
  );
  await auth.bootstrap();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: auth),
        ChangeNotifierProvider.value(value: chat),
        ChangeNotifierProvider.value(value: drive),
        ChangeNotifierProvider.value(value: voice),
        Provider.value(value: webrpc),
      ],
      child: const File2FileApp(),
    ),
  );
}
