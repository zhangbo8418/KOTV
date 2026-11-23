import 'kotv_platform.dart';

/// Win7「硬解直出」开关的落盘值：按当前会话实际状态取反。详情 / 全屏 / 播控共用。
String kotvWin7DirectNextValue(bool currentlyOn) => currentlyOn ? 'false' : 'true';

/// media_kit：直出开却已软解时，D3D9 ANGLE 上 in-place 换 D3D11 会 create_failed（蓝屏），须新建 D3D11 Player。
bool kotvWin7SoftOnDirectNeedsNewPlayer({
  required bool direct,
  required String hwdecCurrent,
}) =>
    kotvIsWindows7() && direct && hwdecCurrent.trim() == 'no';
