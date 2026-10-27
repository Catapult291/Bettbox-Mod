import 'package:bett_box/common/common.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/views/dashboard/widgets/network_speed_data.dart';
import 'package:bett_box/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class NetworkSpeed extends ConsumerWidget {
  const NetworkSpeed({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final color = context.colorScheme.onSurfaceVariant.opacity80;
    final primaryColor = Theme.of(context).colorScheme.primary;
    return SizedBox(
      height: getWidgetHeight(2),
      child: CommonCard(
        onPressed: () {
          globalState.openUrl('https://ptclspeed.speedtestcustom.com');
        },
        info: Info(
          label: appLocalizations.networkSpeed,
          iconData: Icons.speed_sharp,
        ),
        child: RepaintBoundary(
          // 由流量数据驱动，不再跟 tick：内容没变时这两个 provider 返回的还是
          // 上一次的值，卡片不重建（图表再按内容判定是否重绘，见 LineChart）。
          child: Consumer(
            builder: (_, ref, _) {
              final points = ref.watch(networkSpeedPointsProvider);
              final speedText = ref.watch(networkSpeedTextProvider);
              return Stack(
                children: [
                  Positioned.fill(
                    child: Padding(
                      padding: const EdgeInsets.only(
                        top: 16,
                        left: 0,
                        right: 0,
                        bottom: 0,
                      ),
                      child: RepaintBoundary(
                        child: LineChart(
                          gradient: true,
                          color: primaryColor,
                          points: points,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 0,
                    right: 0,
                    child: Transform.translate(
                      offset: const Offset(-16, -20),
                      child: Text(
                        speedText,
                        style: context.textTheme.bodySmall?.copyWith(
                          color: color,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
