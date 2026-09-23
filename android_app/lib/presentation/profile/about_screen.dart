import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';

/// Profile → About: who builds and owns the app. Text supplied by the owner.
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  static final _website = Uri.parse('https://theottdeals.com');

  Future<void> _openWebsite(BuildContext context) async {
    final ok = await launchUrl(_website, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open the website.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    const body = TextStyle(
      color: AppColors.textSecondary,
      fontSize: 15,
      height: 1.55,
    );
    const strong = TextStyle(
      color: AppColors.textPrimary,
      fontWeight: FontWeight.w700,
    );

    Widget para(List<InlineSpan> spans) => Padding(
          padding: const EdgeInsets.only(bottom: Insets.lg),
          child: Text.rich(TextSpan(style: body, children: spans)),
        );

    Widget fact(String label, Widget value) => Padding(
          padding: const EdgeInsets.only(bottom: Insets.md),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 5,
                child: Text(label,
                    style: const TextStyle(
                        color: AppColors.textSecondary, fontSize: 13.5)),
              ),
              const SizedBox(width: Insets.md),
              Expanded(flex: 6, child: value),
            ],
          ),
        );

    const valueStyle = TextStyle(
      color: AppColors.textPrimary,
      fontSize: 14.5,
      fontWeight: FontWeight.w600,
    );

    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(Insets.lg, Insets.sm, Insets.lg,
            MediaQuery.paddingOf(context).bottom + Insets.xxl),
        children: [
          const Text(
            'About the Developer',
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: Insets.lg),
          Row(
            children: [
              Container(
                width: 64,
                height: 64,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                  color: AppColors.accent,
                  shape: BoxShape.circle,
                ),
                child: const Text('HA',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w800)),
              ),
              const SizedBox(width: Insets.lg),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Hammad Ansar',
                        style: TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 24,
                            fontWeight: FontWeight.w700)),
                    SizedBox(height: 4),
                    Text(
                      'Full Stack Web Developer | Founder of TheOttDeals.com',
                      style: TextStyle(
                          color: AppColors.accent,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: Insets.xl),
          para(const [
            TextSpan(
                text: 'TheOttDeals IPTV is proudly designed, developed, and '
                    'maintained by '),
            TextSpan(text: 'Hammad Ansar', style: strong),
            TextSpan(
                text: ', a Full Stack Web Developer and the founder of '
                    'TheOttDeals.com.'),
          ]),
          para(const [
            TextSpan(
                text: 'With a passion for software development, modern '
                    'technologies, and innovative digital solutions, Hammad '
                    'focuses on creating reliable, user-friendly, and '
                    'high-quality applications that deliver a smooth '
                    'experience to users.'),
          ]),
          para(const [
            TextSpan(
                text: 'TheOttDeals IPTV is an independent software '
                    'application developed as part of the TheOttDeals.com '
                    "ecosystem. All rights to the application's original "
                    'design, development, and proprietary software belong to '),
            TextSpan(text: 'TheOttDeals.com', style: strong),
            TextSpan(text: '.'),
          ]),
          para(const [
            TextSpan(
                text: 'Our goal is to build practical and accessible '
                    'technology while maintaining a strong focus on '
                    'performance, usability, and continuous improvement.'),
          ]),
          Container(
            padding: const EdgeInsets.fromLTRB(
                Insets.lg, Insets.lg, Insets.lg, Insets.xs),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(Radii.lg),
            ),
            child: Column(
              children: [
                fact('Developer',
                    const Text('Hammad Ansar', style: valueStyle)),
                fact('Business & Intellectual Property Owner',
                    const Text('TheOttDeals.com', style: valueStyle)),
                fact(
                  'Official Website',
                  InkWell(
                    onTap: () => _openWebsite(context),
                    child: const Text(
                      'https://theottdeals.com',
                      style: TextStyle(
                        color: AppColors.accent,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                        decoration: TextDecoration.underline,
                        decorationColor: AppColors.accent,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: Insets.xl),
          const Center(
            child: Text(
              'Built with passion, developed with purpose.',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 14,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
