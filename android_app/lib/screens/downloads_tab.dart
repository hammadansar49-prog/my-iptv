import 'package:flutter/material.dart';
import '../theme.dart';

class DownloadsTab extends StatelessWidget {
  const DownloadsTab({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Downloads')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 84, height: 84,
                decoration: BoxDecoration(color: AppColors.bg2, shape: BoxShape.circle),
                child: const Icon(Icons.download_outlined, size: 38, color: AppColors.textDim),
              ),
              const SizedBox(height: 18),
              const Text('No downloads yet', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              const Text(
                'Offline downloads for movies and episodes are coming in a future update.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textDim, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
