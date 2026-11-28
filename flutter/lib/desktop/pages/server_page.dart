// original cm window in Sciter version.

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common/widgets/audio_input.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/desktop/widgets/mikzfix_cm_dock.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:flutter_hbb/models/chat_model.dart';
import 'package:flutter_hbb/models/cm_file_model.dart';
import 'package:flutter_hbb/utils/platform_channel.dart';
import 'package:get/get.dart';
import 'package:percent_indicator/linear_percent_indicator.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../common.dart';
import '../../common/widgets/chat_page.dart';
import '../../models/file_model.dart';
import '../../models/platform_model.dart';
import '../../models/server_model.dart';

class DesktopServerPage extends StatefulWidget {
  const DesktopServerPage({Key? key}) : super(key: key);

  @override
  State<DesktopServerPage> createState() => _DesktopServerPageState();
}

class _DesktopServerPageState extends State<DesktopServerPage>
    with WindowListener, AutomaticKeepAliveClientMixin {
  final tabController = gFFI.serverModel.tabController;

  _DesktopServerPageState() {
    gFFI.ffiModel.updateEventListener(gFFI.sessionId, "");
    Get.put<DesktopTabController>(tabController);
    tabController.onRemoved = (_, id) {
      onRemoveId(id);
    };
  }

  @override
  void initState() {
    windowManager.addListener(this);
    super.initState();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowClose() {
    Future.wait([gFFI.serverModel.closeAll(), gFFI.close()]).then((_) {
      if (isMacOS) {
        RdPlatformChannel.instance.terminate();
      } else {
        windowManager.setPreventClose(false);
        windowManager.close();
      }
    });
    super.onWindowClose();
  }

  void onRemoveId(String id) {
    if (tabController.state.value.tabs.isEmpty) {
      windowManager.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: gFFI.serverModel),
        ChangeNotifierProvider.value(value: gFFI.chatModel),
      ],
      child: Consumer<ServerModel>(
        builder: (context, serverModel, child) {
          final body = Scaffold(
            backgroundColor: Theme.of(context).colorScheme.background,
            body: ConnectionManager(),
          );
          return isLinux
              ? buildVirtualWindowFrame(context, body)
              : workaroundWindowBorder(
                  context,
                  Container(
                    decoration: BoxDecoration(
                        border:
                            Border.all(color: MyTheme.color(context).border!)),
                    child: body,
                  ));
        },
      ),
    );
  }

  @override
  bool get wantKeepAlive => true;
}

class ConnectionManager extends StatefulWidget {
  @override
  State<StatefulWidget> createState() => ConnectionManagerState();
}

class ConnectionManagerState extends State<ConnectionManager>
    with WidgetsBindingObserver {
  final RxBool _controlPageBlock = false.obs;
  final RxBool _sidePageBlock = false.obs;

  ConnectionManagerState() {
    gFFI.serverModel.tabController.onSelected = (client_id_str) {
      final client_id = int.tryParse(client_id_str);
      if (client_id != null) {
        final client =
            gFFI.serverModel.clients.firstWhereOrNull((e) => e.id == client_id);
        if (client != null) {
          gFFI.chatModel.changeCurrentKey(MessageKey(client.peerId, client.id));
          if (client.unreadChatMessageCount.value > 0) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              client.unreadChatMessageCount.value = 0;
              gFFI.chatModel.showChatPage(MessageKey(client.peerId, client.id));
            });
          }
          windowManager.setTitle(getWindowNameWithId(client.peerId));
          gFFI.cmFileModel.updateCurrentClientId(client.id);
        }
      }
    };
    gFFI.chatModel.isConnManager = true;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      if (!allowRemoteCMModification()) {
        shouldBeBlocked(_controlPageBlock, null);
        shouldBeBlocked(_sidePageBlock, null);
      }
    }
  }

  @override
  void initState() {
    gFFI.serverModel.updateClientState();
    WidgetsBinding.instance.addObserver(this);
    super.initState();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final serverModel = Provider.of<ServerModel>(context);
    pointerHandler(PointerEvent e) {
      if (serverModel.cmHiddenTimer != null) {
        serverModel.cmHiddenTimer!.cancel();
        serverModel.cmHiddenTimer = null;
        debugPrint("CM hidden timer has been canceled");
      }
    }

    // mikzfix: a new request, voice call or ended session brings the collapsed panel back.
    MikzfixCmDock.watchAttention(serverModel.clients);
    if (serverModel.clients.isEmpty) {
      return Column(
        children: [
          buildTitleBar(),
          Expanded(
            child: Center(
              child: Text(translate("Waiting")),
            ),
          ),
        ],
      );
    }
    // mikzfix: TeamViewer-style panel docked to the screen edge (see mikzfix_cm_dock.dart)
    // instead of upstream's DesktopTab window. Multiple connections are a row of chips under
    // the header; the pages are the same TabInfo pages, kept alive in an IndexedStack.
    return Listener(
      onPointerDown: pointerHandler,
      onPointerMove: pointerHandler,
      child: Obx(() {
        // Read the observables here, not inside LayoutBuilder (which runs at layout time).
        final collapsed = MikzfixCmDock.collapsed.value;
        final tabState = serverModel.tabController.state.value;
        final tabs = tabState.tabs.toList();
        final selected = tabState.selected;
        return LayoutBuilder(builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          // While the window is being resized between states it can briefly have the other
          // state's size; the tab fits anything, the panel needs room.
          if (collapsed || size.width < 200 || size.height < 300) {
            return SizedBox(
              width: size.width,
              height: size.height,
              child: const MikzfixCmEdgeTab(),
            );
          }
          return _buildDockedPanel(size, tabs, selected, serverModel);
        });
      }),
    );
  }

  Widget _buildDockedPanel(Size size, List<TabInfo> tabs, int selected,
      ServerModel serverModel) {
    final showSide = gFFI.chatModel.isShowCMSidePage &&
        size.width >= kMikzfixCmPanelWidth + 200;
    final panelWidth = showSide ? kMikzfixCmPanelWidth : size.width;
    final int index =
        tabs.isEmpty ? 0 : selected.clamp(0, tabs.length - 1).toInt();
    Widget panel = Theme(
      // The panel is always the light brand card, also with the dark app theme.
      data: MyTheme.lightTheme,
      child: Container(
        color: Colors.white,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const MikzfixCmHeaderBar(),
            if (tabs.length > 1) _buildClientSwitcher(tabs, index, serverModel),
            Expanded(
              child: tabs.isEmpty
                  ? const SizedBox.shrink()
                  : IndexedStack(
                      index: index,
                      sizing: StackFit.expand,
                      children: tabs
                          .map((t) =>
                              KeyedSubtree(key: ValueKey(t.key), child: t.page))
                          .toList(),
                    ),
            ),
          ],
        ),
      ),
    );
    if (!allowRemoteCMModification()) {
      panel = buildRemoteBlock(
        child: _buildKeyEventBlock(panel),
        block: _controlPageBlock,
        mask: false,
      );
    }
    return SizedBox(
      width: size.width,
      height: size.height,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showSide)
            Expanded(
              child: Container(
                color: Theme.of(context).scaffoldBackgroundColor,
                child: Consumer<ChatModel>(
                  builder: (_, model, child) => allowRemoteCMModification()
                      ? buildSidePage()
                      : buildRemoteBlock(
                          child: buildSidePage(),
                          block: _sidePageBlock,
                          mask: true),
                ),
              ),
            ),
          if (showSide)
            const VerticalDivider(
                width: 1, thickness: 1, color: MikzfixCmColors.divider),
          SizedBox(width: panelWidth, child: panel),
        ],
      ),
    );
  }

  /// mikzfix: one chip per connection when there is more than one.
  Widget _buildClientSwitcher(
      List<TabInfo> tabs, int selected, ServerModel serverModel) {
    return Container(
      height: 44,
      color: MikzfixCmColors.secondaryBg,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        itemCount: tabs.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (context, i) {
          final tab = tabs[i];
          final client = serverModel.clients
              .firstWhereOrNull((c) => c.id.toString() == tab.key);
          final isSelected = i == selected;
          final label = client == null
              ? tab.label
              : (client.name.isNotEmpty ? client.name : client.peerId);
          return Material(
            color: isSelected ? MikzfixCmColors.brand : Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(15),
              side: BorderSide(
                  color: isSelected
                      ? MikzfixCmColors.brand
                      : MikzfixCmColors.secondaryBorder),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(15),
              onTap: () => serverModel.tabController.jumpTo(i),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 110),
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: isSelected
                              ? Colors.white
                              : MikzfixCmColors.brand,
                        ),
                      ),
                    ),
                    if (client != null)
                      unreadMessageCountBuilder(client.unreadChatMessageCount)
                          .marginOnly(left: 4),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget buildSidePage() {
    final selected = gFFI.serverModel.tabController.state.value.selected;
    if (selected < 0 || selected >= gFFI.serverModel.clients.length) {
      return Offstage();
    }
    final clientType = gFFI.serverModel.clients[selected].type_();
    if (clientType == ClientType.file) {
      return _FileTransferLogPage();
    } else {
      return ChatPage(type: ChatPageType.desktopCM);
    }
  }

  Widget _buildKeyEventBlock(Widget child) {
    return ExcludeFocus(child: child, excluding: true);
  }

  Widget buildTitleBar() {
    return SizedBox(
      height: kDesktopRemoteTabBarHeight,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const _AppIcon(),
          Expanded(
            child: GestureDetector(
              onPanStart: (d) {
                windowManager.startDragging();
              },
              child: Container(
                color: Theme.of(context).colorScheme.background,
              ),
            ),
          ),
          const SizedBox(
            width: 4.0,
          ),
          const _CloseButton()
        ],
      ),
    );
  }

  Widget buildScrollJumper() {
    final offstage = gFFI.serverModel.clients.length < 2;
    final sc = gFFI.serverModel.tabController.state.value.scrollController;
    return Offstage(
        offstage: offstage,
        child: Row(
          children: [
            ActionIcon(
                icon: Icons.arrow_left, iconSize: 22, onTap: sc.backward),
            ActionIcon(
                icon: Icons.arrow_right, iconSize: 22, onTap: sc.forward),
          ],
        ));
  }

  Future<bool> handleWindowCloseButton() async {
    var tabController = gFFI.serverModel.tabController;
    final connLength = tabController.length;
    if (connLength <= 1) {
      windowManager.close();
      return true;
    } else {
      final bool res;
      if (!option2bool(kOptionEnableConfirmClosingTabs,
          bind.mainGetLocalOption(key: kOptionEnableConfirmClosingTabs))) {
        res = true;
      } else {
        res = await closeConfirmDialog();
      }
      if (res) {
        windowManager.close();
      }
      return res;
    }
  }
}

Widget buildConnectionCard(Client client) {
  return Consumer<ServerModel>(
    builder: (context, value, child) =>
        _MikzfixConnectionCard(key: ValueKey(client.id), client: client),
  );
}

/// mikzfix: one connection in the docked panel: status on top, permissions in the middle
/// (scrolls if needed), actions at the bottom with "Terminar sessão" last and largest.
class _MikzfixConnectionCard extends StatefulWidget {
  final Client client;
  const _MikzfixConnectionCard({Key? key, required this.client})
      : super(key: key);

  @override
  State<_MikzfixConnectionCard> createState() => _MikzfixConnectionCardState();
}

class _MikzfixConnectionCardState extends State<_MikzfixConnectionCard>
    with AutomaticKeepAliveClientMixin {
  bool _moreOptions = false;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final client = widget.client;
    final showPrivileges = !(client.type_() == ClientType.file ||
        client.type_() == ClientType.portForward ||
        client.type_() == ClientType.terminal ||
        client.disconnected);
    return Container(
      color: Colors.white,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _CmHeader(client: client),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
              child: showPrivileges
                  ? _PrivilegeBoard(
                      client: client,
                      showMore: _moreOptions,
                      onToggleMore: () =>
                          setState(() => _moreOptions = !_moreOptions),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
          _CmControlPanel(client: client),
        ],
      ),
    );
  }

  @override
  bool get wantKeepAlive => true;
}

class _AppIcon extends StatelessWidget {
  const _AppIcon({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.symmetric(horizontal: 4.0),
      child: loadIcon(30),
    );
  }
}

class _CloseButton extends StatelessWidget {
  const _CloseButton({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: () {
        windowManager.close();
      },
      icon: const Icon(
        IconFont.close,
        size: 18,
      ),
      splashColor: Colors.transparent,
      hoverColor: Colors.transparent,
    );
  }
}

class _CmHeader extends StatefulWidget {
  final Client client;

  const _CmHeader({Key? key, required this.client}) : super(key: key);

  @override
  State<_CmHeader> createState() => _CmHeaderState();
}

class _CmHeaderState extends State<_CmHeader>
    with AutomaticKeepAliveClientMixin {
  Client get client => widget.client;

  final _time = 0.obs;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(Duration(seconds: 1), (_) {
      if (client.authorized && !client.disconnected) {
        _time.value = _time.value + 1;
      }
    });
    // Call onSelected in post frame callback, since we cannot guarantee that the callback will not call setState.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      gFFI.serverModel.tabController.onSelected?.call(client.id.toString());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // mikzfix: status block of the docked panel. Who is connected, in plain words, and the
    // session timer. (Upstream: gradient card with avatar, name and ID, chat button.)
    final name = client.name.isNotEmpty ? client.name : client.peerId;
    final String status;
    final Color statusColor;
    final Color dotColor;
    final String title;
    if (!client.authorized) {
      status = translate('mikzfix_cm_session_request');
      statusColor = MikzfixCmColors.pending;
      dotColor = MikzfixCmColors.pendingDot;
      title = translate('mikzfix_cm_requesting').replaceAll('{}', name);
    } else if (client.disconnected) {
      status = translate('mikzfix_cm_session_ended');
      statusColor = MikzfixCmColors.ended;
      dotColor = MikzfixCmColors.ended;
      title = translate('mikzfix_cm_disconnected').replaceAll('{}', name);
    } else {
      status = translate('mikzfix_cm_session_active');
      statusColor = MikzfixCmColors.active;
      dotColor = MikzfixCmColors.activeDot;
      title = translate('mikzfix_cm_connected').replaceAll('{}', name);
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              MikzfixCmStatusDot(color: dotColor, size: 8),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  status,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: statusColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (client.authorized && !client.disconnected)
                Obx(
                  () => Text(
                    formatDurationToTime(Duration(seconds: _time.value)),
                    style: const TextStyle(
                      color: MikzfixCmColors.title,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            title,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: MikzfixCmColors.title,
              fontSize: 16,
              fontWeight: FontWeight.bold,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 14),
          const Divider(height: 1, thickness: 1, color: MikzfixCmColors.divider),
        ],
      ),
    );
  }

  @override
  bool get wantKeepAlive => true;
}

/// mikzfix: one permission toggle of the panel.
class _MikzfixPerm {
  final String name; // cmSwitchPermission name
  final bool enabled;
  final IconData icon;
  final String label;
  final void Function(bool) set;
  const _MikzfixPerm(this.name, this.enabled, this.icon, this.label, this.set);
}

class _PrivilegeBoard extends StatefulWidget {
  final Client client;
  final bool showMore;
  final VoidCallback onToggleMore;

  const _PrivilegeBoard(
      {Key? key,
      required this.client,
      required this.showMore,
      required this.onToggleMore})
      : super(key: key);

  @override
  State<StatefulWidget> createState() => _PrivilegeBoardState();
}

class _PrivilegeBoardState extends State<_PrivilegeBoard> {
  late final client = widget.client;

  void _switch(_MikzfixPerm p, bool enabled) {
    bind.cmSwitchPermission(connId: client.id, name: p.name, enabled: enabled);
    setState(() => p.set(enabled));
  }

  /// mikzfix: 40 px toggle with our own hover tip ("Ficheiros: permitido") above it.
  Widget _buildToggle(_MikzfixPerm p, {required bool canModify}) {
    final state = translate(p.enabled ? 'mikzfix_cm_allowed' : 'mikzfix_cm_blocked');
    final bg = p.enabled ? MikzfixCmColors.permOnBg : MikzfixCmColors.permOffBg;
    final fg = p.enabled ? MikzfixCmColors.permOnFg : MikzfixCmColors.permOffFg;
    final border =
        p.enabled ? MikzfixCmColors.permOnBorder : MikzfixCmColors.permOffBorder;
    return Tooltip(
      message: '${p.label}: $state',
      preferBelow: false,
      verticalOffset: 26,
      waitDuration: const Duration(milliseconds: 300),
      excludeFromSemantics: true,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: MikzfixCmColors.title,
        borderRadius: BorderRadius.circular(999),
      ),
      textStyle: const TextStyle(color: Colors.white, fontSize: 12),
      child: Semantics(
        button: true,
        toggled: p.enabled,
        label: p.label,
        child: Opacity(
          opacity: canModify ? 1.0 : 0.6,
          child: Material(
            color: bg,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(9),
              side: BorderSide(color: border),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(9),
              onTap: canModify
                  ? () => checkClickTime(client.id, () => _switch(p, !p.enabled))
                  : null,
              child: SizedBox(
                height: 40,
                child: Center(child: Icon(p.icon, color: fg, size: 20)),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRow(List<_MikzfixPerm> perms, {required bool canModify}) {
    final children = <Widget>[];
    for (var i = 0; i < perms.length; i++) {
      if (i > 0) children.add(const SizedBox(width: 8));
      children.add(
          Expanded(child: _buildToggle(perms[i], canModify: canModify)));
    }
    return Row(children: children);
  }

  @override
  Widget build(BuildContext context) {
    final canModifyPermission =
        bind.mainGetBuildinOption(key: kOptionEnablePermChangeInAcceptWindow) !=
            'N';
    final isCamera = client.type_() == ClientType.camera;
    final audio = _MikzfixPerm('audio', client.audio, Icons.volume_up_rounded,
        translate('mikzfix_cm_perm_audio'), (v) => client.audio = v);
    final recording = _MikzfixPerm(
        'recording',
        client.recording,
        Icons.videocam_rounded,
        translate('mikzfix_cm_perm_recording'),
        (v) => client.recording = v);
    // The main four (upstream has no "screen" permission to toggle).
    final List<_MikzfixPerm> primary = isCamera
        ? [audio, recording]
        : [
            _MikzfixPerm('keyboard', client.keyboard, Icons.mouse_rounded,
                translate('mikzfix_cm_perm_keyboard'), (v) => client.keyboard = v),
            _MikzfixPerm('file', client.file, Icons.folder_rounded,
                translate('mikzfix_cm_perm_file'), (v) => client.file = v),
            audio,
            _MikzfixPerm(
                'clipboard',
                client.clipboard,
                Icons.content_paste_rounded,
                translate('mikzfix_cm_perm_clipboard'),
                (v) => client.clipboard = v),
          ];
    // The rest of upstream's toggles, behind "Mais opções".
    final List<_MikzfixPerm> more = isCamera
        ? []
        : [
            _MikzfixPerm('restart', client.restart, Icons.restart_alt_rounded,
                translate('mikzfix_cm_perm_restart'), (v) => client.restart = v),
            recording,
            // only windows support block input
            if (isWindows)
              _MikzfixPerm(
                  'block_input',
                  client.blockInput,
                  Icons.block,
                  translate('mikzfix_cm_perm_block_input'),
                  (v) => client.blockInput = v),
            if (bind.mainSupportedPrivacyModeImpls() != '[]')
              _MikzfixPerm(
                  'privacy_mode',
                  client.privacyMode,
                  Icons.visibility_off,
                  translate('mikzfix_cm_perm_privacy'),
                  (v) => client.privacyMode = v),
          ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          translate('mikzfix_cm_permissions').toUpperCase(),
          style: const TextStyle(
            color: MikzfixCmColors.muted,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
          ),
        ),
        const SizedBox(height: 8),
        _buildRow(primary, canModify: canModifyPermission),
        if (more.isNotEmpty) ...[
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: widget.onToggleMore,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      translate(widget.showMore
                          ? 'mikzfix_cm_fewer_options'
                          : 'mikzfix_cm_more_options'),
                      style: const TextStyle(
                        color: MikzfixCmColors.brand,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Icon(
                      widget.showMore
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      color: MikzfixCmColors.brand,
                      size: 18,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (widget.showMore) ...[
            const SizedBox(height: 8),
            _buildRow(more, canModify: canModifyPermission),
          ],
        ],
      ],
    );
  }
}

class _CmControlPanel extends StatelessWidget {
  final Client client;

  const _CmControlPanel({Key? key, required this.client}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          client.authorized
              ? client.disconnected
                  ? buildDisconnected(context)
                  : buildAuthorized(context)
              : buildUnAuthorized(context),
          // mikzfix: the same "Made by MikzBots" credit as the home page (opens mikzbots.dev).
          const Center(child: MikzBotsCredit()).marginOnly(top: 6),
        ],
      ),
    );
  }

  bool get _hasSidePage =>
      client.type_() == ClientType.remote ||
      client.type_() == ClientType.file ||
      client.type_() == ClientType.camera;

  buildAuthorized(BuildContext context) {
    final bool canElevate = bind.cmCanElevate();
    final model = Provider.of<ServerModel>(context);
    final showElevation = canElevate &&
        model.showElevation &&
        client.type_() == ClientType.remote;
    final isFile = client.type_() == ClientType.file;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (client.inVoiceCall)
          Row(
            children: [
              Expanded(
                child: buildButton(context,
                    color: MyTheme.accent,
                    onClick: null, onTapDown: (details) async {
                  final devicesInfo =
                      await AudioInput.getDevicesInfo(true, true);
                  List<String> devices = devicesInfo['devices'] as List<String>;
                  if (devices.isEmpty) {
                    msgBox(
                      gFFI.sessionId,
                      'custom-nocancel-info',
                      'Prompt',
                      'no_audio_input_device_tip',
                      '',
                      gFFI.dialogManager,
                    );
                    return;
                  }

                  String currentDevice = devicesInfo['current'] as String;
                  final x = details.globalPosition.dx;
                  final y = details.globalPosition.dy;
                  final position = RelativeRect.fromLTRB(x, y, x, y);
                  showMenu(
                    context: context,
                    position: position,
                    items: devices
                        .map((d) => PopupMenuItem<String>(
                              value: d,
                              height: 18,
                              padding: EdgeInsets.zero,
                              onTap: () => AudioInput.setDevice(d, true, true),
                              child: IgnorePointer(
                                  child: RadioMenuButton(
                                value: d,
                                groupValue: currentDevice,
                                onChanged: (v) {
                                  if (v != null)
                                    AudioInput.setDevice(v, true, true);
                                },
                                child: Container(
                                  child: Text(
                                    d,
                                    overflow: TextOverflow.ellipsis,
                                    maxLines: 1,
                                  ),
                                  constraints: BoxConstraints(
                                      maxWidth: kMikzfixCmPanelWidth - 80),
                                ),
                              )),
                            ))
                        .toList(),
                  );
                },
                    icon: Icon(
                      Icons.call_rounded,
                      color: Colors.white,
                      size: 16,
                    ),
                    text: "Audio input",
                    textColor: Colors.white),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: buildButton(
                  context,
                  color: MikzfixCmColors.danger,
                  onClick: () => closeVoiceCall(),
                  icon: Icon(
                    Icons.call_end_rounded,
                    color: Colors.white,
                    size: 16,
                  ),
                  text: "Stop voice call",
                  textColor: Colors.white,
                ),
              )
            ],
          ),
        if (client.incomingVoiceCall)
          Row(
            children: [
              Expanded(
                child: buildButton(context,
                    color: MyTheme.accent,
                    onClick: () => handleVoiceCall(true),
                    icon: Icon(
                      Icons.call_rounded,
                      color: Colors.white,
                      size: 16,
                    ),
                    text: "Accept",
                    textColor: Colors.white),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: buildButton(
                  context,
                  color: MikzfixCmColors.danger,
                  onClick: () => handleVoiceCall(false),
                  icon: Icon(
                    Icons.phone_disabled_rounded,
                    color: Colors.white,
                    size: 16,
                  ),
                  text: "Dismiss",
                  textColor: Colors.white,
                ),
              )
            ],
          ),
        if (client.fromSwitch)
          buildButton(context,
              color: Colors.purple,
              onClick: () => handleSwitchBack(context),
              icon: Icon(Icons.reply, color: Colors.white, size: 16),
              text: "Switch Sides",
              textColor: Colors.white),
        if (showElevation)
          buildButton(
            context,
            color: MyTheme.accent,
            onClick: () {
              handleElevate(context);
              // mikzfix: collapse to the edge tab (upstream minimized; there is no
              // taskbar entry to bring it back from).
              MikzfixCmDock.collapse();
            },
            icon: Icon(
              Icons.security_rounded,
              color: Colors.white,
              size: 16,
            ),
            text: 'Elevate',
            textColor: Colors.white,
          ),
        if (_hasSidePage)
          buildButton(
            context,
            color: MikzfixCmColors.secondaryBg,
            border: Border.all(color: MikzfixCmColors.secondaryBorder),
            height: 44,
            onClick: () {
              if (isFile) {
                gFFI.chatModel.toggleCMFilePage();
              } else {
                gFFI.chatModel
                    .toggleCMChatPage(MessageKey(client.peerId, client.id));
              }
            },
            icon: Icon(
              isFile ? Icons.swap_vert_rounded : Icons.chat_bubble_outline_rounded,
              color: MikzfixCmColors.brand,
              size: 18,
            ),
            text: isFile ? 'mikzfix_cm_transfers' : 'mikzfix_cm_chat',
            textColor: MikzfixCmColors.brand,
            fontWeight: FontWeight.w600,
            trailing: unreadMessageCountBuilder(client.unreadChatMessageCount)
                .marginOnly(left: 6),
          ),
        const SizedBox(height: 4),
        buildButton(context,
            color: MikzfixCmColors.danger,
            height: 48,
            onClick: handleDisconnect,
            text: 'mikzfix_cm_end_session',
            icon: Icon(
              Icons.close_rounded,
              color: Colors.white,
              size: 20,
            ),
            textColor: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.bold),
      ],
    );
  }

  buildDisconnected(BuildContext context) {
    return buildButton(context,
        color: MikzfixCmColors.brand,
        height: 48,
        onClick: handleClose,
        text: 'Close',
        textColor: Colors.white,
        fontSize: 15,
        fontWeight: FontWeight.bold);
  }

  buildUnAuthorized(BuildContext context) {
    final bool canElevate = bind.cmCanElevate();
    final model = Provider.of<ServerModel>(context);
    final showElevation = canElevate &&
        model.showElevation &&
        client.type_() == ClientType.remote;
    final showAccept = model.approveMode != 'password';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showElevation && showAccept)
          buildButton(context, color: Colors.green[700], onClick: () {
            handleAccept(context);
            handleElevate(context);
            // mikzfix: collapse instead of minimize (no taskbar entry).
            MikzfixCmDock.collapse();
          },
              text: 'Accept and Elevate',
              icon: Icon(
                Icons.security_rounded,
                color: Colors.white,
                size: 16,
              ),
              textColor: Colors.white,
              tooltip: 'accept_and_elevate_btn_tooltip'),
        if (showAccept)
          buildButton(
            context,
            color: MikzfixCmColors.brand,
            height: 48,
            onClick: () {
              // mikzfix: upstream minimized here; the panel now collapses to its edge
              // tab by itself after kMikzfixCmAutoCollapseDelay (see ServerModel._addTab).
              handleAccept(context);
            },
            text: 'Accept',
            textColor: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.bold,
          ),
        buildButton(
          context,
          color: MikzfixCmColors.secondaryBg,
          border: Border.all(color: MikzfixCmColors.secondaryBorder),
          height: 44,
          onClick: handleDisconnect,
          text: 'Cancel',
          textColor: MikzfixCmColors.brand,
          fontWeight: FontWeight.w600,
        ),
      ],
    );
  }

  Widget buildButton(BuildContext context,
      {required Color? color,
      GestureTapCallback? onClick,
      Widget? icon,
      BoxBorder? border,
      required String text,
      required Color? textColor,
      String? tooltip,
      GestureTapDownCallback? onTapDown,
      double height = 40,
      double fontSize = 13,
      FontWeight? fontWeight,
      Widget? trailing}) {
    assert(!(onClick == null && onTapDown == null));
    final borderRadius = BorderRadius.circular(10.0);
    final btn = Container(
      height: height,
      decoration: BoxDecoration(
          color: color, borderRadius: borderRadius, border: border),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: borderRadius,
          onTap: () {
            if (onClick == null) return;
            checkClickTime(client.id, onClick);
          },
          onTapDown: (details) {
            if (onTapDown == null) return;
            checkClickTime(client.id, () {
              onTapDown.call(details);
            });
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null) icon.marginOnly(right: 8),
                Flexible(
                  child: Text(
                    translate(text),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: textColor,
                        fontSize: fontSize,
                        fontWeight: fontWeight),
                  ),
                ),
                if (trailing != null) trailing,
              ],
            ),
          ),
        ),
      ),
    );
    return (tooltip != null
            ? Tooltip(
                message: translate(tooltip),
                child: btn,
              )
            : btn)
        .marginSymmetric(vertical: 4);
  }

  void handleDisconnect() {
    bind.cmCloseConnection(connId: client.id);
  }

  void handleAccept(BuildContext context) {
    final model = Provider.of<ServerModel>(context, listen: false);
    model.sendLoginResponse(client, true);
  }

  void handleElevate(BuildContext context) {
    final model = Provider.of<ServerModel>(context, listen: false);
    model.setShowElevation(false);
    bind.cmElevatePortable(connId: client.id);
  }

  void handleClose() async {
    await bind.cmRemoveDisconnectedConnection(connId: client.id);
    if (await bind.cmGetClientsLength() == 0) {
      windowManager.close();
    }
  }

  void handleSwitchBack(BuildContext context) {
    bind.cmSwitchBack(connId: client.id);
  }

  void handleVoiceCall(bool accept) {
    bind.cmHandleIncomingVoiceCall(id: client.id, accept: accept);
  }

  void closeVoiceCall() {
    bind.cmCloseVoiceCall(id: client.id);
  }
}

void checkClickTime(int id, Function() callback) async {
  if (allowRemoteCMModification()) {
    callback();
    return;
  }
  var clickCallbackTime = DateTime.now().millisecondsSinceEpoch;
  await bind.cmCheckClickTime(connId: id);
  Timer(const Duration(milliseconds: 120), () async {
    var d = clickCallbackTime - await bind.cmGetClickTime();
    if (d > 120) callback();
  });
}

bool allowRemoteCMModification() {
  return option2bool(kOptionAllowRemoteCmModification,
      bind.mainGetLocalOption(key: kOptionAllowRemoteCmModification));
}

class _FileTransferLogPage extends StatefulWidget {
  _FileTransferLogPage({Key? key}) : super(key: key);

  @override
  State<_FileTransferLogPage> createState() => __FileTransferLogPageState();
}

class __FileTransferLogPageState extends State<_FileTransferLogPage> {
  @override
  Widget build(BuildContext context) {
    return statusList();
  }

  Widget generateCard(Widget child) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.all(
          Radius.circular(15.0),
        ),
      ),
      child: child,
    );
  }

  iconLabel(CmFileLog item) {
    switch (item.action) {
      case CmFileAction.none:
        return Container();
      case CmFileAction.localToRemote:
      case CmFileAction.remoteToLocal:
        return Column(
          children: [
            Transform.rotate(
              angle: item.action == CmFileAction.remoteToLocal ? 0 : pi,
              child: SvgPicture.asset(
                "assets/arrow.svg",
                colorFilter: svgColor(Theme.of(context).tabBarTheme.labelColor),
              ),
            ),
            Text(item.action == CmFileAction.remoteToLocal
                ? translate('Send')
                : translate('Receive'))
          ],
        );
      case CmFileAction.remove:
        return Column(
          children: [
            Icon(
              Icons.delete,
              color: Theme.of(context).tabBarTheme.labelColor,
            ),
            Text(translate('Delete'))
          ],
        );
      case CmFileAction.createDir:
        return Column(
          children: [
            Icon(
              Icons.create_new_folder,
              color: Theme.of(context).tabBarTheme.labelColor,
            ),
            Text(translate('Create Folder'))
          ],
        );
      case CmFileAction.rename:
        return Column(
          children: [
            Icon(
              Icons.drive_file_move_outlined,
              color: Theme.of(context).tabBarTheme.labelColor,
            ),
            Text(translate('Rename'))
          ],
        );
    }
  }

  Widget statusList() {
    return PreferredSize(
      preferredSize: const Size(200, double.infinity),
      child: Container(
          padding: const EdgeInsets.all(12.0),
          child: Obx(
            () {
              final jobTable = gFFI.cmFileModel.currentJobTable;
              statusListView(List<CmFileLog> jobs) => ListView.builder(
                    controller: ScrollController(),
                    itemBuilder: (BuildContext context, int index) {
                      final item = jobs[index];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 5),
                        child: generateCard(
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  SizedBox(
                                    width: 50,
                                    child: iconLabel(item),
                                  ).paddingOnly(left: 15),
                                  const SizedBox(
                                    width: 16.0,
                                  ),
                                  Expanded(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          item.fileName,
                                        ).paddingSymmetric(vertical: 10),
                                        if (item.totalSize > 0)
                                          Text(
                                            '${translate("Total")} ${readableFileSize(item.totalSize.toDouble())}',
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: MyTheme.darkGray,
                                            ),
                                          ),
                                        if (item.totalSize > 0)
                                          Offstage(
                                            offstage: item.state !=
                                                JobState.inProgress,
                                            child: Text(
                                              '${translate("Speed")} ${readableFileSize(item.speed)}/s',
                                              style: TextStyle(
                                                fontSize: 12,
                                                color: MyTheme.darkGray,
                                              ),
                                            ),
                                          ),
                                        Offstage(
                                          offstage: !(item.isTransfer() &&
                                              item.state !=
                                                  JobState.inProgress),
                                          child: Text(
                                            translate(
                                              item.display(),
                                            ),
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: MyTheme.darkGray,
                                            ),
                                          ),
                                        ),
                                        if (item.totalSize > 0)
                                          Offstage(
                                            offstage: item.state !=
                                                JobState.inProgress,
                                            child: LinearPercentIndicator(
                                              padding:
                                                  EdgeInsets.only(right: 15),
                                              animateFromLastPercent: true,
                                              center: Text(
                                                '${(item.finishedSize / item.totalSize * 100).toStringAsFixed(0)}%',
                                              ),
                                              barRadius: Radius.circular(15),
                                              percent: item.finishedSize /
                                                  item.totalSize,
                                              progressColor: MyTheme.accent,
                                              backgroundColor:
                                                  Theme.of(context).hoverColor,
                                              lineHeight:
                                                  kDesktopFileTransferRowHeight,
                                            ).paddingSymmetric(vertical: 15),
                                          ),
                                      ],
                                    ),
                                  ),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.end,
                                    children: [],
                                  ),
                                ],
                              ),
                            ],
                          ).paddingSymmetric(vertical: 10),
                        ),
                      );
                    },
                    itemCount: jobTable.length,
                  );

              return jobTable.isEmpty
                  ? generateCard(
                      Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            SvgPicture.asset(
                              "assets/transfer.svg",
                              colorFilter: svgColor(
                                  Theme.of(context).tabBarTheme.labelColor),
                              height: 40,
                            ).paddingOnly(bottom: 10),
                            Text(
                              translate("No transfers in progress"),
                              textAlign: TextAlign.center,
                              textScaler: TextScaler.linear(1.20),
                              style: TextStyle(
                                  color:
                                      Theme.of(context).tabBarTheme.labelColor),
                            ),
                          ],
                        ),
                      ),
                    )
                  : statusListView(jobTable);
            },
          )),
    );
  }
}
