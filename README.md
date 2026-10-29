# Flutter Ride App

A Flutter/Firebase ride-booking app. The admin ride report includes a
strictly-free historical demand outlook for fleet planning.

## Admin demand outlook

The report reuses its bounded Firestore read (the most recent 35 days, capped
at 1,000 rides) and derives analytics in memory on the device. It does not use
Cloud Functions, paid AI, external analytics services, or added packages, and
does not add fields to ride documents.

For the current UTC weekday, previous matching weekdays fully within the
rolling window are aggregated into 96 quarter-hour (`historicalTimeBucket`)
averages (the partial oldest date is excluded). Four
quarter-hour averages are summed into each hourly value. Pickup coordinates
that are numeric, finite, and within latitude/longitude ranges are snapped to
a 0.01-degree grid for approximate `demandClusterId` groups and per-zone
hourly trends. At San Francisco, Agusan del Sur's latitude, a grid cell is
about 1.1 km north–south; its east–west width varies by latitude. These are
pickup-coordinate clusters, not trained clusters or authoritative municipal
boundaries; the report is not geofenced to municipal limits. Missing or invalid
timestamps are skipped, and rides with invalid or missing coordinates remain
part of the existing report metrics but are excluded from zone analytics.
When the ride query reaches its 1,000-record cap, only fully covered matching
dates after the oldest included record are used as comparison dates.

The chart and fleet suggestions are historical weekday-matched averages, not
an AI/ML model or a guarantee of future demand. Use them as planning cues and
apply local operational judgment.

## Getting started

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter documentation](https://docs.flutter.dev/)
