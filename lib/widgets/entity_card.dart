import 'package:flutter/material.dart';
import '../core/theme.dart';
import 'status_pill.dart';

/// The app's signature element: a colored left edge that carries the same
/// meaning everywhere a task or ticket appears (feed, list, calendar day) —
/// so status is readable from a glance down the edge of the list, not just
/// from the pill text.
class EntityCard extends StatelessWidget {
  final String title;
  final String status;
  final String? subtitle;
  final IconData leadingIcon;
  final VoidCallback? onTap;

  const EntityCard({
    super.key,
    required this.title,
    required this.status,
    required this.leadingIcon,
    this.subtitle,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final style = StatusStyle.of(status);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: IntrinsicHeight(
          child: Row(
            children: [
              Container(width: 4, color: style.fg),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(Gap.lg),
                  child: Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(color: style.bg, borderRadius: BorderRadius.circular(10)),
                        child: Icon(leadingIcon, color: style.fg, size: 20),
                      ),
                      const SizedBox(width: Gap.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            if (subtitle != null) ...[
                              const SizedBox(height: 2),
                              Text(
                                subtitle!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: Gap.sm),
                      StatusPill(status: status),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
