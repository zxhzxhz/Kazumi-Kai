import 'dart:io';

import 'package:flutter/material.dart';
import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/pages/player/controller/player_super_resolution.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/bean/settings/settings_list.dart';

class SuperResolutionSettings extends StatefulWidget {
  const SuperResolutionSettings({super.key});

  @override
  State<SuperResolutionSettings> createState() =>
      _SuperResolutionSettingsState();
}

class _SuperResolutionSettingsState extends State<SuperResolutionSettings> {
  late bool disableWarning;
  late SuperResolutionMode superResolutionMode;
  late bool videoEnhanceEnabled;
  late bool videoEnhanceInterpolationEnabled;
  late int videoEnhanceAnime4kLevel;

  @override
  void initState() {
    super.initState();
    disableWarning = GStorage.getSetting<bool>(
      SettingsKeys.disableSuperResolutionWarning,
    );
    superResolutionMode = SuperResolutionMode.fromStorageValue(
      GStorage.getSetting<int>(SettingsKeys.defaultSuperResolutionMode),
    );
    videoEnhanceEnabled =
        GStorage.getSetting<int>(SettingsKeys.videoEnhanceMode) != 0;
    videoEnhanceInterpolationEnabled = GStorage.getSetting<bool>(
      SettingsKeys.videoEnhanceInterpolation,
    );
    videoEnhanceAnime4kLevel =
        GStorage.getSetting<int>(SettingsKeys.videoEnhanceAnime4k);
  }

  @override
  Widget build(BuildContext context) {
    return SettingsDetailScaffold(
      title: const Text('超分辨率'),
      body: SettingsList(
        sections: [
          SettingsRadioSection<SuperResolutionMode>(
            title: Text('超分辨率需要启用硬件解码, 若启用硬件解码后仍然不生效, 尝试切换视频渲染器为 gpu'),
            groupValue: superResolutionMode,
            onChanged: (SuperResolutionMode? value) {
              if (value == null) return;
              GStorage.putSetting<int>(
                SettingsKeys.defaultSuperResolutionMode,
                value.storageValue,
              );
              setState(() {
                superResolutionMode = value;
              });
            },
            tiles: [
              for (final mode in SuperResolutionMode.values)
                SettingsTile<SuperResolutionMode>.radioTile(
                  title: Text(mode.label),
                  description: Text(mode.description),
                  radioValue: mode,
                ),
            ],
          ),
          SettingsSection(
            title: Text('默认行为'),
            tiles: [
              SettingsTile.switchTile(
                leading: Icons.notifications_off_rounded,
                title: Text('关闭提示'),
                description: Text('关闭每次启用超分辨率时的提示'),
                initialValue: disableWarning,
                onToggle: (value) async {
                  disableWarning = value ?? !disableWarning;
                  await GStorage.putSetting<bool>(
                    SettingsKeys.disableSuperResolutionWarning,
                    disableWarning,
                  );
                  if (mounted) setState(() {});
                },
              ),
            ],
          ),
          SettingsSection(
            title: const Text('iOS 26+ 视频增强'),
            tiles: [
              SettingsTile.switchTile(
                leading: Icons.auto_awesome_rounded,
                title: const Text('视频增强总开关'),
                description:
                    const Text('需要 iPadOS 26 及以上；仅 iOS 生效，其它平台忽略'),
                initialValue: videoEnhanceEnabled,
                enabled: Platform.isIOS,
                onToggle: (value) async {
                  videoEnhanceEnabled = value ?? !videoEnhanceEnabled;
                  await GStorage.putSetting<int>(
                    SettingsKeys.videoEnhanceMode,
                    videoEnhanceEnabled ? 1 : 0,
                  );
                  if (mounted) setState(() {});
                },
              ),
              SettingsTile.switchTile(
                leading: Icons.movie_filter_rounded,
                title: const Text('VT 插帧（2x）'),
                description: const Text('用 VideoToolbox 在相邻帧之间生成中间帧，需 iPadOS 26'),
                initialValue: videoEnhanceInterpolationEnabled,
                enabled: Platform.isIOS && videoEnhanceEnabled,
                onToggle: (value) async {
                  videoEnhanceInterpolationEnabled =
                      value ?? !videoEnhanceInterpolationEnabled;
                  await GStorage.putSetting<bool>(
                    SettingsKeys.videoEnhanceInterpolation,
                    videoEnhanceInterpolationEnabled,
                  );
                  if (mounted) setState(() {});
                },
              ),
            ],
          ),
          RadioGroup<int>(
            groupValue: videoEnhanceAnime4kLevel,
            onChanged: (int? value) {
              if (value == null) return;
              GStorage.putSetting<int>(
                SettingsKeys.videoEnhanceAnime4k,
                value,
              );
              setState(() {
                videoEnhanceAnime4kLevel = value;
              });
            },
            child: SettingsSection(
              title: const Text('Metal Anime4K'),
              tiles: [
                SettingsTile<int>.radioTile(
                  title: const Text('关闭'),
                  description: const Text('不启用 Anime4K 着色器'),
                  radioValue: 0,
                  enabled: Platform.isIOS && videoEnhanceEnabled,
                ),
                SettingsTile<int>.radioTile(
                  title: const Text('效率'),
                  description: const Text('效率档，适合性能有限的设备'),
                  radioValue: 1,
                  enabled: Platform.isIOS && videoEnhanceEnabled,
                ),
                SettingsTile<int>.radioTile(
                  title: const Text('质量'),
                  description: const Text('质量档，效果更好但更耗性能'),
                  radioValue: 2,
                  enabled: Platform.isIOS && videoEnhanceEnabled,
                ),
              ],
              bottomInfo: const Text('开启 Anime4K 时会自动清空 mpv 的 glsl-shaders，避免双重锐化'),
            ),
          ),
        ],
      ),
    );
  }
}
