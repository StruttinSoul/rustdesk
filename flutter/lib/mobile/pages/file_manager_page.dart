import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_breadcrumb/flutter_breadcrumb.dart';
import 'package:flutter_hbb/models/file_model.dart';
import 'package:get/get.dart';
import 'package:uuid/uuid.dart';

import '../../common.dart';
import '../../common/widgets/dialog.dart';
import '../../consts.dart';
import '../../models/model.dart';
import '../widgets/mirpg_remote_theme.dart';

class FileManagerPage extends StatefulWidget {
  FileManagerPage(
      {Key? key,
      required this.id,
      this.password,
      this.isSharedPassword,
      this.forceRelay,
      this.connToken,
      this.embedded = false,
      this.initiallyShowRemote = false})
      : super(key: key);
  final String id;
  final String? password;
  final bool? isSharedPassword;
  final bool? forceRelay;
  final String? connToken;
  final bool embedded;
  final bool initiallyShowRemote;

  @override
  State<StatefulWidget> createState() => _FileManagerPageState();
}

enum SelectMode { local, remote, none }

extension SelectModeEq on SelectMode {
  bool eq(bool? currentIsLocal) {
    if (currentIsLocal == null) {
      return false;
    }
    if (currentIsLocal) {
      return this == SelectMode.local;
    } else {
      return this == SelectMode.remote;
    }
  }
}

extension SelectModeExt on Rx<SelectMode> {
  void toggle(bool currentIsLocal) {
    switch (value) {
      case SelectMode.local:
        value = SelectMode.none;
        break;
      case SelectMode.remote:
        value = SelectMode.none;
        break;
      case SelectMode.none:
        if (currentIsLocal) {
          value = SelectMode.local;
        } else {
          value = SelectMode.remote;
        }
        break;
    }
  }
}

class _FileManagerPageState extends State<FileManagerPage> {
  late final FFI _ffi;
  late final FileModel model;
  final selectMode = SelectMode.none.obs;

  var showLocal = true;

  FileController get currentFileController =>
      showLocal ? model.localController : model.remoteController;
  FileDirectory get currentDir => currentFileController.directory.value;
  DirectoryOptions get currentOptions => currentFileController.options.value;
  final _uniqueKey = UniqueKey();

  Future<T> _runAndroidDocumentPicker<T>(Future<T> Function() action) async {
    _ffi.ffiModel.beginAndroidDocumentPicker();
    try {
      return await action();
    } finally {
      _ffi.ffiModel.endAndroidDocumentPicker();
    }
  }

  Future<void> _importFiles() async {
    var imported = 0;
    var failed = false;
    final importController = currentFileController;
    final importDirectory = currentDir.path;
    final importIsWindows = currentOptions.isWindows;
    try {
      final selectedFiles = await _runAndroidDocumentPicker(() =>
          _ffi.invokeMethodWithResult<List<dynamic>>(
              AndroidChannel.kPickImportFiles));
      if (selectedFiles == null || selectedFiles.isEmpty) return;

      for (final selected in selectedFiles) {
        final uri = (selected as Map<dynamic, dynamic>)['uri'] as String?;
        final selectedName = selected['name'] as String?;
        final name = selectedName?.replaceAll('\\', '/').split('/').last;
        if (uri == null ||
            name == null ||
            !PathUtil.validName(name, importIsWindows)) {
          failed = true;
          continue;
        }
        final destination =
            PathUtil.join(importDirectory, name, importIsWindows);
        var overwrite = false;
        if (await File(destination).exists()) {
          final overwriteResult = await model.showFileConfirmDialog(
              translate('Overwrite'), destination, false, false);
          if (overwriteResult == false) break;
          if (overwriteResult != true) continue;
          overwrite = true;
        }
        try {
          final success = await _ffi.invokeMethod(AndroidChannel.kImportFile,
              {'uri': uri, 'path': destination, 'overwrite': overwrite});
          if (success == true) {
            imported++;
          } else {
            failed = true;
          }
        } catch (e) {
          failed = true;
          debugPrint('Failed to import $name: $e');
        }
      }
    } catch (e) {
      failed = true;
      debugPrint('Failed to select files for import: $e');
    }
    await importController.refresh();
    if (failed) {
      showToast(translate('Failed'));
    } else if (imported > 0) {
      showToast(translate('Successful'));
    }
  }

  Future<void> _exportFile(Entry entry) async {
    try {
      final exported = await _runAndroidDocumentPicker(() =>
          _ffi.invokeMethod(AndroidChannel.kExportFile, {'path': entry.path}));
      if (exported == true) {
        showToast(translate('Successful'));
      }
    } catch (e) {
      debugPrint('Failed to export ${entry.name}: $e');
      showToast(translate('Failed'));
    }
  }

  Future<void> _importFolder() async {
    final importController = currentFileController;
    final importDirectory = currentDir.path;
    final importIsWindows = currentOptions.isWindows;
    try {
      final picked = await _runAndroidDocumentPicker(() =>
          _ffi.invokeMethodWithResult<Map<dynamic, dynamic>>(
              AndroidChannel.kPickImportDirectory));
      if (picked == null || picked.isEmpty) return;
      final uri = picked['uri'] as String?;
      final name =
          (picked['name'] as String?)?.replaceAll('\\', '/').split('/').last;
      if (uri == null ||
          name == null ||
          name == '.' ||
          name == '..' ||
          !PathUtil.validName(name, importIsWindows)) {
        showToast(translate('Failed'));
        return;
      }
      final destination = PathUtil.join(importDirectory, name, importIsWindows);
      final destinationType = await FileSystemEntity.type(destination);
      var overwrite = false;
      if (destinationType == FileSystemEntityType.directory) {
        final overwriteResult = await model.showFileConfirmDialog(
            translate('Overwrite'), destination, false, false);
        if (overwriteResult != true) return;
        overwrite = true;
      } else if (destinationType != FileSystemEntityType.notFound) {
        showToast(translate('Failed'));
        return;
      }
      final success = await _ffi.invokeMethod(AndroidChannel.kImportDirectory,
          {'uri': uri, 'path': destination, 'overwrite': overwrite});
      if (success == true) {
        showToast(translate('Successful'));
      } else {
        showToast(translate('Failed'));
      }
    } catch (e) {
      debugPrint('Failed to import folder: $e');
      showToast(translate('Failed'));
    }
    await importController.refresh();
  }

  Future<void> _exportItems(SelectedItems items) async {
    await _exportPaths(items.items.map((e) => e.path));
  }

  Future<void> _exportLogs() async {
    final home = currentFileController.homePath;
    if (home.isEmpty) {
      showToast(translate('Failed'));
      return;
    }
    final appDir = PathUtil.join(home, appName, false);
    final paths = [
      PathUtil.join(appDir, 'Logs', false),
      PathUtil.join(appDir, 'ScreenRecord', false),
    ].where((p) => File(p).existsSync() || Directory(p).existsSync()).toList();
    if (paths.isEmpty) {
      showToast(translate('Failed'));
      return;
    }
    await _exportPaths(paths);
  }

  Future<void> _exportPaths(Iterable<String> paths) async {
    try {
      final result = await _runAndroidDocumentPicker(() => _ffi
          .invokeMethodWithResult<Map<dynamic, dynamic>>(
              AndroidChannel.kExportFiles, {'paths': paths.toList()}));
      if (result == null) return;
      final exported = result['exported'] as int? ?? 0;
      final failed = result['failed'] as int? ?? 0;
      if (failed > 0) {
        showToast(translate('Failed'));
      } else if (exported > 0) {
        showToast(translate('Successful'));
      }
    } catch (e) {
      debugPrint('Failed to export paths: $e');
      showToast(translate('Failed'));
    }
  }

  @override
  void initState() {
    super.initState();
    showLocal = !widget.initiallyShowRemote;
    _ffi = widget.embedded || widget.connToken != null
        ? FFI(Uuid().v4obj())
        : gFFI;
    model = _ffi.fileModel;
    _ffi.start(widget.id,
        isFileTransfer: true,
        password: widget.password,
        isSharedPassword: widget.isSharedPassword,
        connToken: widget.connToken,
        forceRelay: widget.forceRelay);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ffi.dialogManager.showLoading(translate('Connecting...'),
          onCancel: widget.embedded ? _ffi.close : closeConnection);
    });
    if (!widget.embedded) {
      _ffi.ffiModel.updateEventListener(_ffi.sessionId, widget.id);
    }
    WakelockManager.enable(_uniqueKey);
  }

  @override
  void dispose() {
    model.close().whenComplete(() {
      _ffi.close();
      _ffi.dialogManager.dismissAll();
      WakelockManager.disable(_uniqueKey);
    });
    model.jobController.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => WillPopScope(
      onWillPop: () async {
        if (selectMode.value != SelectMode.none) {
          selectMode.value = SelectMode.none;
          setState(() {});
          return false;
        }
        if (widget.embedded) {
          // Let the dashboard's PopScope switch back to Devices.
          return true;
        } else {
          currentFileController.goBack();
        }
        return false;
      },
      child: Scaffold(
        // backgroundColor: MyTheme.grayBg,
        appBar: AppBar(
          automaticallyImplyLeading: !widget.embedded,
          leading: widget.embedded
              ? null
              : Row(children: [
                  IconButton(
                      icon: Icon(Icons.close),
                      onPressed: () => clientClose(_ffi.sessionId, _ffi)),
                ]),
          centerTitle: widget.embedded,
          title: SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(
                value: true,
                icon: const Icon(Icons.phone_android_sharp, size: 18),
                label: Text(translate("Local")),
              ),
              ButtonSegment(
                value: false,
                icon: const Icon(Icons.screen_share, size: 18),
                label: Text(translate("Remote")),
              ),
            ],
            selected: {showLocal},
            onSelectionChanged: (selection) {
              final next = selection.first;
              if (next != showLocal) setState(() => showLocal = next);
            },
          ),
          actions: [
            PopupMenuButton<String>(
                tooltip: "",
                icon: Icon(Icons.more_vert),
                itemBuilder: (context) {
                  return [
                    PopupMenuItem(
                      child: Row(
                        children: [
                          Icon(Icons.refresh,
                              color: Theme.of(context).iconTheme.color),
                          SizedBox(width: 5),
                          Text(translate("Refresh File"))
                        ],
                      ),
                      value: "refresh",
                    ),
                    if (isAndroid)
                      PopupMenuItem(
                        enabled: showLocal && currentDir.path.isNotEmpty,
                        value: "import",
                        child: Row(
                          children: [
                            Icon(Icons.add_to_drive,
                                color: Theme.of(context).iconTheme.color),
                            SizedBox(width: 5),
                            Text(translate("Add"))
                          ],
                        ),
                      ),
                    if (isAndroid)
                      PopupMenuItem(
                        enabled: showLocal && currentDir.path.isNotEmpty,
                        value: "import_folder",
                        child: Row(
                          children: [
                            Icon(Icons.create_new_folder_outlined,
                                color: Theme.of(context).iconTheme.color),
                            SizedBox(width: 5),
                            Text(translate("Import Folder"))
                          ],
                        ),
                      ),
                    if (isAndroid)
                      PopupMenuItem(
                        enabled: showLocal && currentDir.path.isNotEmpty,
                        value: "export_logs",
                        child: Row(
                          children: [
                            Icon(Icons.article_outlined,
                                color: Theme.of(context).iconTheme.color),
                            SizedBox(width: 5),
                            Text(translate("Export Logs"))
                          ],
                        ),
                      ),
                    PopupMenuItem(
                      enabled: currentDir.path != "/",
                      child: Row(
                        children: [
                          Icon(Icons.check,
                              color: Theme.of(context).iconTheme.color),
                          SizedBox(width: 5),
                          Text(translate("Multi Select"))
                        ],
                      ),
                      value: "select",
                    ),
                    PopupMenuItem(
                      enabled: currentDir.path != "/",
                      child: Row(
                        children: [
                          Icon(Icons.folder_outlined,
                              color: Theme.of(context).iconTheme.color),
                          SizedBox(width: 5),
                          Text(translate("Create Folder"))
                        ],
                      ),
                      value: "folder",
                    ),
                    PopupMenuItem(
                      enabled: currentDir.path != "/",
                      child: Row(
                        children: [
                          Icon(
                              currentOptions.showHidden
                                  ? Icons.check_box_outlined
                                  : Icons.check_box_outline_blank,
                              color: Theme.of(context).iconTheme.color),
                          SizedBox(width: 5),
                          Text(translate("Show Hidden Files"))
                        ],
                      ),
                      value: "hidden",
                    )
                  ];
                },
                onSelected: (v) {
                  if (v == "refresh") {
                    currentFileController.refresh();
                  } else if (v == "import") {
                    _importFiles();
                  } else if (v == "import_folder") {
                    _importFolder();
                  } else if (v == "export_logs") {
                    _exportLogs();
                  } else if (v == "select") {
                    model.localController.selectedItems.clear();
                    model.remoteController.selectedItems.clear();
                    selectMode.toggle(showLocal);
                    setState(() {});
                  } else if (v == "folder") {
                    final name = TextEditingController();
                    String? errorText;
                    _ffi.dialogManager.show((setState, close, context) {
                      name.addListener(() {
                        if (errorText != null) {
                          setState(() {
                            errorText = null;
                          });
                        }
                      });
                      return CustomAlertDialog(
                          title: Text(translate("Create Folder")),
                          content: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              TextFormField(
                                decoration: InputDecoration(
                                  labelText:
                                      translate("Please enter the folder name"),
                                  errorText: errorText,
                                ),
                                controller: name,
                              ).workaroundFreezeLinuxMint(),
                            ],
                          ),
                          actions: [
                            dialogButton("Cancel",
                                onPressed: () => close(false), isOutline: true),
                            dialogButton("OK", onPressed: () {
                              if (name.value.text.isNotEmpty) {
                                if (!PathUtil.validName(
                                    name.value.text,
                                    currentFileController
                                        .options.value.isWindows)) {
                                  setState(() {
                                    errorText =
                                        translate("Invalid folder name");
                                  });
                                  return;
                                }
                                currentFileController.createDir(PathUtil.join(
                                    currentDir.path,
                                    name.value.text,
                                    currentOptions.isWindows));
                                close();
                              }
                            })
                          ]);
                    });
                  } else if (v == "hidden") {
                    currentFileController.toggleShowHidden();
                  }
                }),
          ],
        ),
        body: showLocal
            ? FileManagerView(
                controller: model.localController,
                selectMode: selectMode,
                remoteVersion: () => _ffi.ffiModel.pi.version,
              )
            : FileManagerView(
                controller: model.remoteController,
                selectMode: selectMode,
                remoteVersion: () => _ffi.ffiModel.pi.version,
              ),
        bottomSheet: bottomSheet(),
      ));

  Widget? bottomSheet() {
    return Obx(() {
      final selectedItems = getActiveSelectedItems();
      final jobTable = model.jobController.jobTable;

      final localLabel = selectedItems?.isLocal == null
          ? ""
          : " [${selectedItems!.isLocal ? translate("Local") : translate("Remote")}]";
      if (!(selectMode.value == SelectMode.none)) {
        final selectedItemsLen =
            "${selectedItems?.items.length ?? 0} ${translate("items")}";
        if (selectedItems == null ||
            selectedItems.items.isEmpty ||
            selectMode.value.eq(showLocal)) {
          return BottomSheetBody(
              leading: Icon(Icons.check),
              title: translate("Selected"),
              text: selectedItemsLen + localLabel,
              onCanceled: () {
                selectedItems?.items.clear();
                selectMode.value = SelectMode.none;
                setState(() {});
              },
              actions: [
                if (isAndroid &&
                    selectedItems?.isLocal == true &&
                    selectedItems?.items.isNotEmpty == true) ...[
                  if (selectedItems!.items.length == 1 &&
                      selectedItems!.items.single.isFile)
                    IconButton(
                      tooltip: translate("Save as"),
                      icon: Icon(Icons.save_alt),
                      onPressed: () => _exportFile(selectedItems!.items.single),
                    )
                  else
                    IconButton(
                      tooltip: translate("Export"),
                      icon: Icon(Icons.drive_folder_upload),
                      onPressed: () => _exportItems(selectedItems!),
                    ),
                ],
                IconButton(
                  icon: Icon(Icons.compare_arrows),
                  onPressed: () => setState(() => showLocal = !showLocal),
                ),
                IconButton(
                  icon: Icon(Icons.delete_forever),
                  onPressed: selectedItems != null
                      ? () async {
                          if (selectedItems.items.isNotEmpty) {
                            await currentFileController
                                .removeAction(selectedItems);
                            selectedItems.items.clear();
                            selectMode.value = SelectMode.none;
                          }
                        }
                      : null,
                )
              ]);
        } else {
          return BottomSheetBody(
              leading: Icon(Icons.input),
              title: translate("Paste here?"),
              text: selectedItemsLen + localLabel,
              onCanceled: () {
                selectedItems.items.clear();
                selectMode.value = SelectMode.none;
                setState(() {});
              },
              actions: [
                IconButton(
                  icon: Icon(Icons.compare_arrows),
                  onPressed: () => setState(() => showLocal = !showLocal),
                ),
                IconButton(
                  icon: Icon(Icons.paste),
                  onPressed: () {
                    selectMode.value = SelectMode.none;
                    final otherSide = showLocal
                        ? model.remoteController
                        : model.localController;
                    final thisSideData =
                        DirectoryData(currentDir, currentOptions);
                    otherSide.sendFiles(selectedItems, thisSideData);
                    selectedItems.items.clear();
                    selectMode.value = SelectMode.none;
                  },
                )
              ]);
        }
      }

      if (jobTable.isEmpty) {
        return Offstage();
      }

      // Rust processes transfer jobs sequentially. Keep acknowledged/pending
      // transfer lifecycle states attached to the same active row instead of
      // falling through to whichever job happens to be last in the list.
      final activeJob = jobTable.firstWhereOrNull((job) => {
                JobState.inProgress,
                JobState.pauseRequested,
                JobState.paused,
                JobState.resumeRequested,
                JobState.interrupted,
                JobState.cancelRequested,
              }.contains(job.state)) ??
          jobTable.last;
      final filePermission = _ffi.ffiModel.permissions['file'] != false;
      final pauseSupported = _ffi.ffiModel.pi.features.filePause;
      final resumeSupported =
          versionCmp(_ffi.ffiModel.pi.version, '1.4.2') >= 0;

      switch (activeJob.state) {
        case JobState.inProgress:
          return BottomSheetBody(
            leading: CircularProgressIndicator(),
            title: translate("Transfer file"),
            text: "${readableFileSize(activeJob.speed)}/s",
            onCanceled: () {
              model.jobController.cancelJob(activeJob.id);
            },
            actions: pauseSupported && filePermission
                ? [
                    IconButton(
                      tooltip: 'Pause transfer',
                      icon: const Icon(Icons.pause_rounded),
                      onPressed: () => model.jobController.pauseJob(
                        activeJob.id,
                        supported: true,
                      ),
                    )
                  ]
                : null,
          );
        case JobState.pauseRequested:
          return BottomSheetBody(
            leading: const CircularProgressIndicator(),
            title: 'Pausing…',
            text: activeJob.fileName,
            onCanceled: () => model.jobController.cancelJob(activeJob.id),
          );
        case JobState.paused:
          return BottomSheetBody(
            leading: const Icon(Icons.pause_circle_outline_rounded),
            title: translate('Paused'),
            text: activeJob.fileName,
            onCanceled: () => model.jobController.cancelJob(activeJob.id),
            actions: resumeSupported && filePermission
                ? [
                    IconButton(
                      tooltip: 'Resume transfer',
                      icon: const Icon(Icons.play_arrow_rounded),
                      onPressed: () =>
                          model.jobController.resumeJob(activeJob.id),
                    )
                  ]
                : null,
          );
        case JobState.resumeRequested:
          return BottomSheetBody(
            leading: const CircularProgressIndicator(),
            title: 'Resuming…',
            text: activeJob.fileName,
            onCanceled: () => model.jobController.cancelJob(activeJob.id),
          );
        case JobState.interrupted:
          return BottomSheetBody(
            leading: const Icon(Icons.warning_amber_rounded),
            title: 'Interrupted',
            text: activeJob.err.isNotEmpty
                ? activeJob.err.replaceFirst('pause_outcome_unknown: ', '')
                : activeJob.fileName,
            onCanceled: () => model.jobController.cancelJob(activeJob.id),
            actions: resumeSupported && filePermission
                ? [
                    IconButton(
                      tooltip: 'Resume transfer',
                      icon: const Icon(Icons.play_arrow_rounded),
                      onPressed: () =>
                          model.jobController.resumeJob(activeJob.id),
                    )
                  ]
                : null,
          );
        case JobState.cancelRequested:
          return BottomSheetBody(
            leading: const CircularProgressIndicator(),
            title: 'Cancelling…',
            text: activeJob.fileName,
          );
        case JobState.done:
          return BottomSheetBody(
            leading: Icon(Icons.check),
            title: "${translate("Successful")}!",
            text: activeJob.display(),
            onCanceled: () => jobTable.clear(),
          );
        case JobState.error:
          return BottomSheetBody(
            leading: Icon(Icons.error),
            title: "${translate("Error")}!",
            text: activeJob.err.isNotEmpty ? activeJob.err : activeJob.fileName,
            onCanceled: () => jobTable.clear(),
          );
        case JobState.none:
          break;
        case JobState.cancelled:
          return BottomSheetBody(
            leading: const Icon(Icons.cancel_outlined),
            title: 'Cancelled',
            text: activeJob.err.isNotEmpty ? activeJob.err : activeJob.fileName,
            onCanceled: () => jobTable.remove(activeJob),
          );
      }
      return Offstage();
    });
  }

  SelectedItems? getActiveSelectedItems() {
    final localSelectedItems = model.localController.selectedItems;
    final remoteSelectedItems = model.remoteController.selectedItems;

    if (localSelectedItems.items.isNotEmpty &&
        remoteSelectedItems.items.isNotEmpty) {
      // assert unreachable
      debugPrint("Wrong SelectedItems state, reset");
      localSelectedItems.clear();
      remoteSelectedItems.clear();
    }

    if (localSelectedItems.items.isEmpty && remoteSelectedItems.items.isEmpty) {
      return null;
    }

    if (localSelectedItems.items.length > remoteSelectedItems.items.length) {
      return localSelectedItems;
    } else {
      return remoteSelectedItems;
    }
  }
}

class FileManagerView extends StatefulWidget {
  final FileController controller;
  final Rx<SelectMode> selectMode;
  final String Function() remoteVersion;

  FileManagerView({
    required this.controller,
    required this.selectMode,
    required this.remoteVersion,
  });

  @override
  State<StatefulWidget> createState() => _FileManagerViewState();
}

class _FileManagerViewState extends State<FileManagerView> {
  final _listScrollController = ScrollController();
  final _breadCrumbScroller = ScrollController();
  late final ascending = Rx<bool>(controller.sortAscending);

  bool get isLocal => widget.controller.isLocal;
  FileController get controller => widget.controller;
  SelectedItems get _selectedItems => widget.controller.selectedItems;

  @override
  void initState() {
    super.initState();
    controller.directory.listen((e) => breadCrumbScrollToEnd());
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      headTools(),
      Expanded(child: Obx(() {
        final entries = controller.directory.value.entries;
        return ListView.builder(
          controller: _listScrollController,
          itemCount: entries.length + 1,
          itemBuilder: (context, index) {
            if (index >= entries.length) {
              return listTail();
            }
            var selected = false;
            if (widget.selectMode.value != SelectMode.none) {
              selected = _selectedItems.items.contains(entries[index]);
            }

            final sizeStr = entries[index].isFile
                ? readableFileSize(entries[index].size.toDouble())
                : "";

            final showCheckBox = () {
              return widget.selectMode.value != SelectMode.none &&
                  widget.selectMode.value.eq(controller.selectedItems.isLocal);
            }();
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: entries[index].isDrive
                      ? Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: Image(
                              image: iconHardDrive,
                              fit: BoxFit.scaleDown,
                              color: Theme.of(context)
                                  .iconTheme
                                  .color
                                  ?.withOpacity(0.7)))
                      : Icon(
                          entries[index].isFile
                              ? Icons.feed_outlined
                              : Icons.folder,
                          size: 32),
                  title: Text(entries[index].name),
                  selected: selected,
                  subtitle: entries[index].isDrive
                      ? null
                      : Text(
                          "${entries[index].lastModified().toString().replaceAll(".000", "")}   $sizeStr",
                          style: const TextStyle(
                              fontSize: 12,
                              color: MirpgRemoteTheme.textSecondary),
                        ),
                  trailing: entries[index].isDrive
                      ? null
                      : showCheckBox
                          ? Checkbox(
                              value: selected,
                              onChanged: (v) {
                                if (v == null) return;
                                if (v && !selected) {
                                  _selectedItems.add(entries[index]);
                                } else if (!v && selected) {
                                  _selectedItems.remove(entries[index]);
                                }
                                setState(() {});
                              })
                          : PopupMenuButton<String>(
                              tooltip: "",
                              icon: Icon(Icons.more_vert),
                              itemBuilder: (context) {
                                return [
                                  PopupMenuItem(
                                    child: Text(translate("Delete")),
                                    value: "delete",
                                  ),
                                  PopupMenuItem(
                                    child: Text(translate("Multi Select")),
                                    value: "multi_select",
                                  ),
                                  PopupMenuItem(
                                    child: Text(translate("Properties")),
                                    value: "properties",
                                    enabled: false,
                                  ),
                                  if (!entries[index].isDrive &&
                                      versionCmp(widget.remoteVersion(),
                                              "1.3.0") >=
                                          0)
                                    PopupMenuItem(
                                      child: Text(translate("Rename")),
                                      value: "rename",
                                    )
                                ];
                              },
                              onSelected: (v) {
                                if (v == "delete") {
                                  final items = SelectedItems(isLocal: isLocal);
                                  items.add(entries[index]);
                                  controller.removeAction(items);
                                } else if (v == "multi_select") {
                                  _selectedItems.clear();
                                  widget.selectMode.toggle(isLocal);
                                  setState(() {});
                                } else if (v == "rename") {
                                  controller.renameAction(
                                      entries[index], isLocal);
                                }
                              }),
                  onTap: () {
                    if (showCheckBox) {
                      if (selected) {
                        _selectedItems.remove(entries[index]);
                      } else {
                        _selectedItems.add(entries[index]);
                      }
                      setState(() {});
                      return;
                    }
                    if (entries[index].isDirectory || entries[index].isDrive) {
                      controller.openDirectory(entries[index].path);
                    } else {
                      // Perform file-related tasks.
                    }
                  },
                  onLongPress: entries[index].isDrive
                      ? null
                      : () {
                          _selectedItems.clear();
                          widget.selectMode.toggle(isLocal);
                          if (widget.selectMode.value != SelectMode.none) {
                            _selectedItems.add(entries[index]);
                          }
                          setState(() {});
                        },
                ),
                if (index < entries.length - 1)
                  const Divider(height: 1, indent: 64),
              ],
            );
          },
        );
      }))
    ]);
  }

  void breadCrumbScrollToEnd() {
    Future.delayed(Duration(milliseconds: 200), () {
      if (_breadCrumbScroller.hasClients) {
        _breadCrumbScroller.animateTo(
            _breadCrumbScroller.position.maxScrollExtent,
            duration: Duration(milliseconds: 200),
            curve: Curves.fastLinearToSlowEaseIn);
      }
    });
  }

  Widget headTools() => Container(
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      decoration: const BoxDecoration(
        color: MirpgRemoteTheme.surface,
        border: Border(bottom: BorderSide(color: MirpgRemoteTheme.divider)),
      ),
      child: Row(
        children: [
          Expanded(child: Obx(() {
            final home = controller.options.value.home;
            final isWindows = controller.options.value.isWindows;
            return BreadCrumb(
              items: getPathBreadCrumbItems(controller.shortPath, isWindows,
                  () => controller.goToHomeDirectory(), (list) {
                var path = "";
                if (home.startsWith(list[0])) {
                  // absolute path
                  for (var item in list) {
                    path = PathUtil.join(path, item, isWindows);
                  }
                } else {
                  path += home;
                  for (var item in list) {
                    path = PathUtil.join(path, item, isWindows);
                  }
                }
                controller.openDirectory(path);
              }),
              divider: Icon(Icons.chevron_right),
              overflow: ScrollableOverflow(controller: _breadCrumbScroller),
            );
          })),
          Row(
            children: [
              IconButton(
                icon: Icon(Icons.arrow_back),
                onPressed: controller.goBack,
              ),
              IconButton(
                icon: Icon(Icons.arrow_upward),
                onPressed: controller.goToParentDirectory,
              ),
              PopupMenuButton<SortBy>(
                  tooltip: "",
                  icon: Icon(Icons.sort),
                  itemBuilder: (context) {
                    return SortBy.values
                        .map((e) => PopupMenuItem(
                              child: Text(translate(e.toString())),
                              value: e,
                            ))
                        .toList();
                  },
                  onSelected: (sortBy) {
                    // If selecting the same sort option, flip the order
                    // If selecting a different sort option, use ascending order
                    if (controller.sortBy.value == sortBy) {
                      ascending.value = !controller.sortAscending;
                    } else {
                      ascending.value = true;
                    }
                    controller.changeSortStyle(sortBy,
                        ascending: ascending.value);
                  }),
            ],
          )
        ],
      ));

  Widget listTail() => Obx(() => Container(
        height: 100,
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(30, 5, 30, 0),
              child: Text(
                controller.directory.value.path,
                style: const TextStyle(color: MirpgRemoteTheme.textSecondary),
              ),
            ),
            Padding(
              padding: EdgeInsets.all(2),
              child: Text(
                "${translate("Total")}: ${controller.directory.value.entries.length} ${translate("items")}",
                style: const TextStyle(color: MirpgRemoteTheme.textSecondary),
              ),
            )
          ],
        ),
      ));

  List<BreadCrumbItem> getPathBreadCrumbItems(String shortPath, bool isWindows,
      void Function() onHome, void Function(List<String>) onPressed) {
    final list = PathUtil.split(shortPath, isWindows);
    final breadCrumbList = [
      BreadCrumbItem(
          content: IconButton(
        icon: Icon(Icons.home_filled),
        onPressed: onHome,
      ))
    ];
    breadCrumbList.addAll(list.asMap().entries.map((e) => BreadCrumbItem(
        content: TextButton(
            child: Text(e.value),
            style:
                ButtonStyle(minimumSize: MaterialStateProperty.all(Size(0, 0))),
            onPressed: () => onPressed(list.sublist(0, e.key + 1))))));
    return breadCrumbList;
  }
}

class BottomSheetBody extends StatelessWidget {
  BottomSheetBody(
      {required this.leading,
      required this.title,
      required this.text,
      this.onCanceled,
      this.actions});

  final Widget leading;
  final String title;
  final String text;
  final VoidCallback? onCanceled;
  final List<IconButton>? actions;

  @override
  BottomSheet build(BuildContext context) {
    // ignore: no_leading_underscores_for_local_identifiers
    final _actions = actions ?? [];
    return BottomSheet(
      builder: (BuildContext context) {
        return Container(
            height: 65,
            alignment: Alignment.centerLeft,
            decoration: BoxDecoration(
                color: MirpgRemoteTheme.raised,
                border: const Border(
                    top: BorderSide(color: MirpgRemoteTheme.outline)),
                borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(MirpgRemoteTheme.sheetRadius))),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 15),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      leading,
                      SizedBox(width: 16),
                      Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title, style: TextStyle(fontSize: 18)),
                          Text(text,
                              style: TextStyle(fontSize: 14)) // TODO color
                        ],
                      )
                    ],
                  ),
                  Row(children: () {
                    _actions.add(IconButton(
                      icon: Icon(Icons.cancel_outlined),
                      onPressed: onCanceled,
                    ));
                    return _actions;
                  }())
                ],
              ),
            ));
      },
      onClosing: () {},
      // backgroundColor: MyTheme.grayBg,
      enableDrag: false,
    );
  }
}
