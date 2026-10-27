import 'package:bett_box/common/common.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/views/dashboard/widgets/network_speed_data.dart';
import 'package:bett_box/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class NetworkSpeedSmall extends ConsumerWidget {
  const NetworkSpeedSmall({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final primaryColor = Theme.of(context).colorScheme.primary;
    return RepaintBoundary(
      child: SizedBox(
        height: getWidgetHeight(1),
        child: CommonCard(
          onPressed: () {
            globalState.openUrl('https://ptclspeed.speedtestcustom.com');
          },
          info: Info(
            label: appLocalizations.networkSpeed,
            iconData: Icons.speed_sharp,
          ),
          child: Consumer(
            // 由流量数据驱动，不再跟 tick：内容没变时 provider 返回的还是上一次
            // 的列表实例，卡片不重建。
            builder: (_, ref, _) {
              final points = ref.watch(networkSpeedPointsProvider);
              return Padding(
                padding: const EdgeInsets.only(
                  top: 16,
                  left: 0,
                  right: 0,
                  bottom: 0,
                ),
                child: LineChart(
                  gradient: true,
                  color: primaryColor,
                  points: points,
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
