import 'dart:math';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/app.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class TrafficUsage extends StatefulWidget {
  const TrafficUsage({super.key});

  @override
  State<TrafficUsage> createState() => _TrafficUsageState();
}

class _TrafficUsageState extends State<TrafficUsage> {
  // cache text measurement results
  Size? _uploadTextSize;
  Size? _downloadTextSize;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // dependency changes when clear cache
    _uploadTextSize = null;
    _downloadTextSize = null;
  }

  Size _getUploadTextSize(BuildContext context) {
    return _uploadTextSize ??= globalState.measure.computeTextSize(
      Text(
        appLocalizations.upload,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: context.textTheme.bodySmall,
      ),
    );
  }

  Size _getDownloadTextSize(BuildContext context) {
    return _downloadTextSize ??= globalState.measure.computeTextSize(
      Text(
        appLocalizations.download,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: context.textTheme.bodySmall,
      ),
    );
  }

  Widget _buildTrafficDataItem(
    BuildContext context,
    Icon icon,
    TrafficValue trafficValue,
  ) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      mainAxisSize: MainAxisSize.max,
      children: [
        Flexible(
          flex: 1,
          child: Row(
            mainAxisSize: MainAxisSize.max,
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              icon,
              const SizedBox(width: 8),
              Flexible(
                flex: 1,
                child: Text(
                  trafficValue.showValue,
                  style: context.textTheme.bodySmall,
                  maxLines: 1,
                ),
              ),
            ],
          ),
        ),
        Text(
          trafficValue.showUnit,
          style: context.textTheme.bodySmall?.toLighter,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final primaryColor = globalState.theme.darken3PrimaryContainer;
    final secondaryColor = globalState.theme.darken2SecondaryContainer;
    return SizedBox(
      height: getWidgetHeight(2),
      child: CommonCard(
        info: Info(
          label: appLocalizations.trafficUsage,
          iconData: Icons.data_saver_off,
        ),
        onPressed: () {},
        child: Consumer(
          builder: (_, ref, _) {
            // 只随累计流量的显示数值重建：内核停止或连接中无流量时累计字节数
            // 不变，tick 不该驱动本卡（改前每秒重排整卡并重新起一次圆环动画）。
            final total = ref.watch(
              totalTrafficProvider.select((t) => (t.up.value, t.down.value)),
            );
            final upTotalTrafficValue = TrafficValue(value: total.$1);
            final downTotalTrafficValue = TrafficValue(value: total.$2);
            return Padding(
              padding: baseInfoEdgeInsets.copyWith(top: 0),
              child: Column(
                mainAxisSize: MainAxisSize.max,
                mainAxisAlignment: MainAxisAlignment.end,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Flexible(
                    child: Container(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Row(
                        mainAxisSize: MainAxisSize.max,
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          AspectRatio(
                            aspectRatio: 1,
                            child: DonutChart(
                              data: [
                                DonutChartData(
                                  value: upTotalTrafficValue.value.toDouble(),
                                  color: primaryColor,
                                ),
                                DonutChartData(
                                  value: downTotalTrafficValue.value.toDouble(),
                                  color: secondaryColor,
                                ),
                              ],
                            ),
                          ),
                          SizedBox(width: 8),
                          Flexible(
                            child: LayoutBuilder(
                              builder: (_, container) {
                                final uploadTextSize = _getUploadTextSize(
                                  context,
                                );
                                final downloadTextSize = _getDownloadTextSize(
                                  context,
                                );
                                final maxTextWidth = max(
                                  uploadTextSize.width,
                                  downloadTextSize.width,
                                );
                                if (maxTextWidth + 24 > container.maxWidth) {
                                  return Container();
                                }
                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Container(
                                          width: 20,
                                          height: 8,
                                          decoration: BoxDecoration(
                                            color: primaryColor,
                                            borderRadius:
                                                BorderRadius.circular(3),
                                          ),
                                        ),
                                        SizedBox(width: 4),
                                        Text(
                                          maxLines: 1,
                                          appLocalizations.upload,
                                          overflow: TextOverflow.ellipsis,
                                          style: context.textTheme.bodySmall,
                                        ),
                                      ],
                                    ),
                                    SizedBox(height: 4),
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Container(
                                          width: 20,
                                          height: 8,
                                          decoration: BoxDecoration(
                                            color: secondaryColor,
                                            borderRadius:
                                                BorderRadius.circular(3),
                                          ),
                                        ),
                                        SizedBox(width: 4),
                                        Text(
                                          maxLines: 1,
                                          appLocalizations.download,
                                          overflow: TextOverflow.ellipsis,
                                          style: context.textTheme.bodySmall,
                                        ),
                                      ],
                                    ),
                                  ],
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  _buildTrafficDataItem(
                    context,
                    Icon(Icons.arrow_upward, color: primaryColor, size: 14),
                    upTotalTrafficValue,
                  ),
                  const SizedBox(height: 8),
                  _buildTrafficDataItem(
                    context,
                    Icon(
                      Icons.arrow_downward,
                      color: secondaryColor,
                      size: 14,
                    ),
                    downTotalTrafficValue,
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
