import 'kotv_platform.dart';
import 'mpv_opts.dart';

/// Win7「硬解直出」切换：落盘值 + 是否须换 Player（ANGLE 后端随 dxva2 变）。
/// 详情 / 直播 / 设置共用，避免各写一份。
String kotvWin7DirectNextValue(bool currentlyOn) => currentlyOn ? 'false' : 'true';

bool kotvWin7DirectToggleNeedsNewPlayer({
  required KotvMpvOpts from,
  required bool nextDirect,
}) =>
    kotvMpvNeedsNewPlayer(from, from.copyWith(direct: nextDirect));

/// 直出开却已软解：D3D9 ANGLE 上 in-place 换 D3D11 会 create_failed（蓝屏），须新建 D3D11 Player。
bool kotvWin7SoftOnDirectNeedsNewPlayer({
  required bool direct,
  required String hwdecCurrent,
}) =>
    kotvIsWindows7() && direct && hwdecCurrent.trim() == 'no';
