import { initializeApp } from "firebase-admin/app";
import { createHash, randomBytes } from "node:crypto";
import {
  FieldValue,
  GeoPoint,
  Timestamp,
  getFirestore,
} from "firebase-admin/firestore";
import { getMessaging } from "firebase-admin/messaging";
import { HttpsError, onCall } from "firebase-functions/v2/https";

initializeApp();

const db = getFirestore();
const MAX_MATCH_DISTANCE_KM = 5;
const DRIVER_LOCATION_MAX_AGE_MS = 3 * 60 * 1000;
const MAX_LOCATION_ACCURACY_METERS = 100;
const MAX_START_DISTANCE_FROM_PICKUP_KM = 0.5;
const TRIP_QR_TTL_MS = 5 * 60 * 1000;
const BASE_FARE_PHP = 15;
const FARE_PER_KILOMETER_PHP = 8;
const COOPERATIVE_SHARE_PERCENT = 30;
const COOPERATIVE_SHARE_RATE = COOPERATIVE_SHARE_PERCENT / 100;
const FARE_ALLOCATION_POLICY_VERSION = "cooperative_30_driver_70_v1";
const MAX_REPORT_RIDES = 5000;
const callableOptions = { enforceAppCheck: true };
const PICKUP_SERVICE_AREA_CENTER: Coordinates = {
  latitude: 8.5050281,
  longitude: 125.9771179,
};
const PICKUP_SERVICE_AREA_RADIUS_KM = 5;

type Coordinates = {
  latitude: number;
  longitude: number;
};

function calculateFare(distanceKmValue: number): number {
  return Math.round((BASE_FARE_PHP + FARE_PER_KILOMETER_PHP * distanceKmValue) * 100) / 100;
}

async function notifyUser(
  uid: string,
  title: string,
  body: string,
  data: Record<string, string>,
): Promise<void> {
  try {
    const tokenSnapshot = await db
      .collection("device_tokens")
      .where("uid", "==", uid)
      .limit(20)
      .get();
    if (tokenSnapshot.empty) return;
    const tokens = tokenSnapshot.docs.map((document) => document.get("token") as string);
    const result = await getMessaging().sendEachForMulticast({
      tokens,
      notification: { title, body },
      data,
      android: { priority: "high" },
    });
    const staleTokens = tokenSnapshot.docs.filter((_, index) => {
      const errorCode = result.responses[index].error?.code;
      return errorCode === "messaging/registration-token-not-registered" ||
        errorCode === "messaging/invalid-registration-token";
    });
    await Promise.all(staleTokens.map((document) => document.ref.delete()));
    if (result.failureCount > staleTokens.length) {
      console.warn(`Some push notifications to ${uid} could not be delivered.`);
    }
  } catch (error) {
    console.warn(`Push notification delivery failed for ${uid}:`, error);
  }
}

async function notifyOnlineDrivers(
  driverIds: string[],
  rideId: string,
): Promise<void> {
  await Promise.all(
    driverIds.map((driverId) =>
      notifyUser(
        driverId,
        "Ride request available",
        "A passenger ride request is waiting in the dispatch queue.",
        { type: "ride_request", rideId },
      ),
    ),
  );
}

function parseLocationAccuracy(value: unknown): number {
  if (
    typeof value !== "number" ||
    !Number.isFinite(value) ||
    value < 0 ||
    value > MAX_LOCATION_ACCURACY_METERS
  ) {
    throw new HttpsError(
      "failed-precondition",
      `Location accuracy must be within ${MAX_LOCATION_ACCURACY_METERS} meters.`,
    );
  }
  return value;
}

function parseCoordinates(value: unknown, field: string): Coordinates {
  if (typeof value !== "object" || value === null) {
    throw new HttpsError("invalid-argument", `${field} coordinates are required.`);
  }
  const coordinates = value as Record<string, unknown>;
  const latitude = coordinates.latitude;
  const longitude = coordinates.longitude;
  if (
    typeof latitude !== "number" ||
    typeof longitude !== "number" ||
    !Number.isFinite(latitude) ||
    !Number.isFinite(longitude) ||
    latitude < -90 ||
    latitude > 90 ||
    longitude < -180 ||
    longitude > 180
  ) {
    throw new HttpsError("invalid-argument", `${field} coordinates are invalid.`);
  }
  return { latitude, longitude };
}

function parseLabel(value: unknown, field: string): string {
  if (typeof value !== "string" || value.trim().length === 0 || value.length > 300) {
    throw new HttpsError("invalid-argument", `${field} is invalid.`);
  }
  return value.trim();
}

function distanceKm(first: Coordinates, second: Coordinates): number {
  const radians = (degrees: number) => (degrees * Math.PI) / 180;
  const latitudeDelta = radians(second.latitude - first.latitude);
  const longitudeDelta = radians(second.longitude - first.longitude);
  const a =
    Math.sin(latitudeDelta / 2) ** 2 +
    Math.cos(radians(first.latitude)) *
      Math.cos(radians(second.latitude)) *
      Math.sin(longitudeDelta / 2) ** 2;
  return 6371 * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

function requirePlausibleMovement(
  previousLocation: unknown,
  previousUpdate: unknown,
  previousAccuracyMeters: unknown,
  nextLocation: Coordinates,
  nextAccuracyMeters: number,
): void {
  if (
    !(previousLocation instanceof GeoPoint) ||
    !(previousUpdate instanceof Timestamp) ||
    Date.now() - previousUpdate.toMillis() > DRIVER_LOCATION_MAX_AGE_MS
  ) {
    return;
  }
  const elapsedHours = (Date.now() - previousUpdate.toMillis()) / 3_600_000;
  if (elapsedHours <= 0) return;
  const measuredDistance = distanceKm(
    {
      latitude: previousLocation.latitude,
      longitude: previousLocation.longitude,
    },
    nextLocation,
  );
  const previousAccuracy =
    typeof previousAccuracyMeters === "number" ? previousAccuracyMeters : 0;
  const distance = Math.max(
    0,
    measuredDistance - (previousAccuracy + nextAccuracyMeters) / 1000,
  );
  if (distance / elapsedHours > 160) {
    throw new HttpsError(
      "failed-precondition",
      "Location changed too quickly. Wait for a fresh GPS reading and try again.",
    );
  }
}

async function requireRole(uid: string, role: "passenger" | "driver"): Promise<void> {
  const user = await db.collection("users").doc(uid).get();
  if (!user.exists || user.get("userType") !== role) {
    throw new HttpsError("permission-denied", `A ${role} account is required.`);
  }
}

async function requireAdmin(uid: string): Promise<void> {
  const user = await db.collection("users").doc(uid).get();
  if (!user.exists || user.get("userType") !== "admin") {
    throw new HttpsError("permission-denied", "An admin account is required.");
  }
}

export const registerPushToken = onCall(callableOptions, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in to register notifications.");
  }
  const token = request.data?.token;
  if (typeof token !== "string" || token.length < 20 || token.length > 4096) {
    throw new HttpsError("invalid-argument", "The notification token is invalid.");
  }
  const tokenRef = db
    .collection("device_tokens")
    .doc(createHash("sha256").update(token).digest("hex"));
  await tokenRef.set({
    uid: request.auth.uid,
    token,
    updatedAt: FieldValue.serverTimestamp(),
  });
  return { registered: true };
});

export const unregisterPushToken = onCall(callableOptions, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in to update notifications.");
  }
  const token = request.data?.token;
  if (typeof token !== "string" || token.length < 20 || token.length > 4096) {
    throw new HttpsError("invalid-argument", "The notification token is invalid.");
  }
  const tokenRef = db
    .collection("device_tokens")
    .doc(createHash("sha256").update(token).digest("hex"));
  await db.runTransaction(async (transaction) => {
    const tokenDocument = await transaction.get(tokenRef);
    if (tokenDocument.exists && tokenDocument.get("uid") === request.auth!.uid) {
      transaction.delete(tokenRef);
    }
  });
  return { unregistered: true };
});

export const setDriverAvailability = onCall(callableOptions, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in to change driver availability.");
  }
  await requireRole(request.auth.uid, "driver");
  if (typeof request.data?.isOnline !== "boolean") {
    throw new HttpsError("invalid-argument", "isOnline must be a boolean.");
  }

  const presenceRef = db.collection("driver_presence").doc(request.auth.uid);
  const isOnline = request.data.isOnline as boolean;
  if (isOnline) {
    const location = parseCoordinates(request.data.location, "Driver");
    const accuracyMeters = parseLocationAccuracy(request.data.accuracyMeters);
    await db.runTransaction(async (transaction) => {
      const presence = await transaction.get(presenceRef);
      if (presence.exists && presence.get("activeRideId")) {
        throw new HttpsError(
          "failed-precondition",
          "Complete your assigned ride before going online.",
        );
      }
      transaction.set(presenceRef, {
        isOnline: true,
        location: new GeoPoint(location.latitude, location.longitude),
        locationAccuracyMeters: accuracyMeters,
        updatedAt: FieldValue.serverTimestamp(),
        activeRideId: null,
      });
    });
  } else {
    await presenceRef.set({
      isOnline: false,
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
  }
  if (isOnline) {
    const waitingRides = await db
      .collection("rides")
      .where("status", "==", "requested")
      .orderBy("createdAt")
      .limit(1)
      .get();
    if (!waitingRides.empty) {
      await notifyUser(
        request.auth.uid,
        "Dispatch queue has rides",
        "Ride requests are waiting. Open the app to review the dispatch queue.",
        { type: "dispatch_queue" },
      );
    }
  }
  return { isOnline };
});

export const updateDriverPresence = onCall(callableOptions, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in to share driver location.");
  }
  await requireRole(request.auth.uid, "driver");
  const location = parseCoordinates(request.data?.location, "Driver");
  const accuracyMeters = parseLocationAccuracy(request.data?.accuracyMeters);
  const presenceRef = db.collection("driver_presence").doc(request.auth.uid);

  await db.runTransaction(async (transaction) => {
    const presence = await transaction.get(presenceRef);
    if (!presence.exists || presence.get("isOnline") !== true) {
      throw new HttpsError("failed-precondition", "Driver is not online.");
    }
    if (presence.get("activeRideId")) {
      throw new HttpsError("failed-precondition", "Driver already has an assigned ride.");
    }
    requirePlausibleMovement(
      presence.get("location"),
      presence.get("updatedAt"),
      presence.get("locationAccuracyMeters"),
      location,
      accuracyMeters,
    );
    transaction.update(presenceRef, {
      location: new GeoPoint(location.latitude, location.longitude),
      locationAccuracyMeters: accuracyMeters,
      updatedAt: FieldValue.serverTimestamp(),
    });
  });
  return { updated: true };
});

export const updateDriverRideLocation = onCall(callableOptions, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in to share driver location.");
  }
  await requireRole(request.auth.uid, "driver");
  const rideId = request.data?.rideId;
  if (typeof rideId !== "string" || rideId.length === 0) {
    throw new HttpsError("invalid-argument", "rideId is required.");
  }
  const location = parseCoordinates(request.data?.location, "Driver");
  const accuracyMeters = parseLocationAccuracy(request.data?.accuracyMeters);
  const rideRef = db.collection("rides").doc(rideId);
  const presenceRef = db.collection("driver_presence").doc(request.auth.uid);

  await db.runTransaction(async (transaction) => {
    const ride = await transaction.get(rideRef);
    const presence = await transaction.get(presenceRef);
    if (
      !ride.exists ||
      ride.get("driverId") !== request.auth!.uid ||
      !["accepted", "in_progress"].includes(ride.get("status"))
    ) {
      throw new HttpsError("permission-denied", "You are not assigned to this ride.");
    }
    requirePlausibleMovement(
      ride.get("driverLocation"),
      ride.get("driverLocationUpdatedAt"),
      ride.get("driverLocationAccuracyMeters"),
      location,
      accuracyMeters,
    );
    transaction.update(rideRef, {
      driverLocation: new GeoPoint(location.latitude, location.longitude),
      driverLocationAccuracyMeters: accuracyMeters,
      driverLocationUpdatedAt: FieldValue.serverTimestamp(),
    });
    if (presence.exists && presence.get("activeRideId") === rideId) {
      transaction.update(presenceRef, {
        location: new GeoPoint(location.latitude, location.longitude),
        locationAccuracyMeters: accuracyMeters,
        updatedAt: FieldValue.serverTimestamp(),
      });
    }
  });
  return { updated: true };
});

export const matchRide = onCall(callableOptions, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in to request a ride.");
  }
  await requireRole(request.auth.uid, "passenger");

  const pickup = parseCoordinates(request.data?.pickup, "Pickup");
  const destination = parseCoordinates(request.data?.destination, "Destination");
  if (
    distanceKm(pickup, PICKUP_SERVICE_AREA_CENTER) >
    PICKUP_SERVICE_AREA_RADIUS_KM
  ) {
    throw new HttpsError(
      "failed-precondition",
      "Pickup must be within 5 km of San Francisco town center.",
    );
  }
  const pickupLabel = parseLabel(request.data?.pickupLabel, "Pickup label");
  const destinationLabel = parseLabel(
    request.data?.destinationLabel,
    "Destination label",
  );
  const tripDistanceKm = distanceKm(pickup, destination);
  const estimatedPrice = calculateFare(tripDistanceKm);

  const now = Date.now();
  const presenceSnapshot = await db
    .collection("driver_presence")
    .where("isOnline", "==", true)
    .get();
  const waitingRides = await db
    .collection("rides")
    .where("status", "==", "requested")
    .orderBy("createdAt")
    .limit(1)
    .get();
  const candidates = presenceSnapshot.docs
    .map((document) => {
      const point = document.get("location");
      const updatedAt = document.get("updatedAt");
      const accuracyMeters = document.get("locationAccuracyMeters");
      if (!(point instanceof GeoPoint) || !(updatedAt instanceof Timestamp)) {
        return null;
      }
      if (
        typeof accuracyMeters !== "number" ||
        accuracyMeters > MAX_LOCATION_ACCURACY_METERS
      ) {
        return null;
      }
      const age = now - updatedAt.toMillis();
      if (age < 0 || age > DRIVER_LOCATION_MAX_AGE_MS) return null;
      const distance = distanceKm(pickup, {
        latitude: point.latitude,
        longitude: point.longitude,
      });
      return { document, distance };
    })
    .filter(
      (candidate): candidate is { document: FirebaseFirestore.QueryDocumentSnapshot; distance: number } =>
        candidate !== null && candidate.distance <= MAX_MATCH_DISTANCE_KM,
    )
    .sort((first, second) => first.distance - second.distance);

  for (const candidate of waitingRides.empty ? candidates : []) {
    const rideRef = db.collection("rides").doc();
    const result = await db.runTransaction(async (transaction) => {
      const activeRideRef = db.collection("passenger_active").doc(request.auth!.uid);
      const latestPresence = await transaction.get(candidate.document.ref);
      const activeRide = await transaction.get(activeRideRef);
      if (activeRide.exists) {
        throw new HttpsError(
          "failed-precondition",
          "You already have an active ride.",
        );
      }
      if (!latestPresence.exists || latestPresence.get("isOnline") !== true) {
        return false;
      }
      const updatedAt = latestPresence.get("updatedAt");
      const location = latestPresence.get("location");
      const accuracyMeters = latestPresence.get("locationAccuracyMeters");
      if (
        !(updatedAt instanceof Timestamp) ||
        now - updatedAt.toMillis() > DRIVER_LOCATION_MAX_AGE_MS ||
        !(location instanceof GeoPoint) ||
        typeof accuracyMeters !== "number" ||
        accuracyMeters > MAX_LOCATION_ACCURACY_METERS
      ) {
        return false;
      }
      const currentDistance = distanceKm(pickup, {
        latitude: location.latitude,
        longitude: location.longitude,
      });
      if (currentDistance > MAX_MATCH_DISTANCE_KM) return false;

      const driverId = candidate.document.id;
      transaction.create(rideRef, {
        passengerId: request.auth!.uid,
        driverId,
        pickupLocation: pickupLabel,
        dropoffLocation: destinationLabel,
        pickupLat: pickup.latitude,
        pickupLng: pickup.longitude,
        dropoffLat: destination.latitude,
        dropoffLng: destination.longitude,
        estimatedPrice,
        finalPrice: null,
        currency: "PHP",
        fareBasis: "base_plus_distance",
        distance: tripDistanceKm,
        status: "accepted",
        dispatchState: "assigned",
        rideType: "economy",
        createdAt: FieldValue.serverTimestamp(),
        matchedDistanceKm: currentDistance,
        driverLocation: location,
        driverLocationAccuracyMeters: accuracyMeters,
        driverLocationUpdatedAt: updatedAt,
      });
      transaction.update(candidate.document.ref, {
        isOnline: false,
        activeRideId: rideRef.id,
        updatedAt: FieldValue.serverTimestamp(),
      });
      transaction.create(activeRideRef, { rideId: rideRef.id });
      return true;
    });

    if (result) {
      await Promise.all([
        notifyUser(
          request.auth.uid,
          "Ride matched",
          "A nearby driver has been assigned to your ride.",
          { type: "ride_assigned", rideId: rideRef.id },
        ),
        notifyUser(
          candidate.document.id,
          "New ride assigned",
          "A passenger ride has been assigned to you.",
          { type: "ride_assigned", rideId: rideRef.id },
        ),
      ]);
      return {
        matched: true,
        rideId: rideRef.id,
        driverId: candidate.document.id,
        distanceKm: candidate.distance,
      };
    }
  }

  const queuedRideRef = db.collection("rides").doc();
  await db.runTransaction(async (transaction) => {
    const activeRideRef = db.collection("passenger_active").doc(request.auth!.uid);
    const activeRide = await transaction.get(activeRideRef);
    if (activeRide.exists) {
      throw new HttpsError(
        "failed-precondition",
        "You already have an active ride.",
      );
    }
    transaction.create(queuedRideRef, {
      passengerId: request.auth!.uid,
      driverId: null,
      pickupLocation: pickupLabel,
      dropoffLocation: destinationLabel,
      pickupLat: pickup.latitude,
      pickupLng: pickup.longitude,
      dropoffLat: destination.latitude,
      dropoffLng: destination.longitude,
      estimatedPrice,
      finalPrice: null,
      currency: "PHP",
      fareBasis: "base_plus_distance",
      distance: tripDistanceKm,
      status: "requested",
      dispatchState: "queued",
      rideType: "economy",
      createdAt: FieldValue.serverTimestamp(),
    });
    transaction.create(activeRideRef, { rideId: queuedRideRef.id });
  });

  await notifyUser(
    request.auth.uid,
    "Ride request queued",
    waitingRides.empty ?
      "No nearby driver was available. Your request is queued for dispatch." :
      "Earlier ride requests are being dispatched first. Your request is queued.",
    { type: "ride_queued", rideId: queuedRideRef.id },
  );
  await notifyOnlineDrivers(
    presenceSnapshot.docs
      .filter((document) => document.get("isOnline") === true)
      .map((document) => document.id),
    queuedRideRef.id,
  );
  return { matched: false, queued: true, rideId: queuedRideRef.id };
});

export const finishRide = onCall(callableOptions, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in to complete a ride.");
  }
  await requireRole(request.auth.uid, "driver");
  const rideId = request.data?.rideId;
  if (typeof rideId !== "string" || rideId.length === 0) {
    throw new HttpsError("invalid-argument", "rideId is required.");
  }
  if (request.data?.cashCollected !== true) {
    throw new HttpsError(
      "failed-precondition",
      "Confirm that the passenger paid the cash fare before completing the ride.",
    );
  }
  const rideRef = db.collection("rides").doc(rideId);
  const presenceRef = db.collection("driver_presence").doc(request.auth.uid);
  const ledgerRef = db.collection("wallet_ledger").doc(rideId);
  let passengerIdForNotification: string | null = null;
  let finalFare = 0;

  await db.runTransaction(async (transaction) => {
    const ride = await transaction.get(rideRef);
    const presence = await transaction.get(presenceRef);
    if (
      !ride.exists ||
      ride.get("driverId") !== request.auth!.uid ||
      ride.get("status") !== "in_progress"
    ) {
      throw new HttpsError("failed-precondition", "Ride cannot be completed.");
    }
    const passengerId = ride.get("passengerId");
    if (typeof passengerId !== "string") {
      throw new HttpsError("failed-precondition", "Ride passenger is invalid.");
    }
    passengerIdForNotification = passengerId;
    const estimatedFare = ride.get("estimatedPrice");
    const distanceKm = ride.get("distance");
    if (
      typeof estimatedFare !== "number" ||
      !Number.isFinite(estimatedFare) ||
      estimatedFare < BASE_FARE_PHP ||
      estimatedFare > 10000 ||
      typeof distanceKm !== "number" ||
      !Number.isFinite(distanceKm) ||
      distanceKm < 0 ||
      distanceKm > 1000
    ) {
      throw new HttpsError("failed-precondition", "Ride fare is invalid.");
    }
    finalFare = estimatedFare;
    const cooperativeFee = finalFare * COOPERATIVE_SHARE_RATE;
    const driverAllocation = finalFare - cooperativeFee;
    const activeRideRef = db.collection("passenger_active").doc(passengerId);
    const activeRide = await transaction.get(activeRideRef);
    const ledgerEntry = await transaction.get(ledgerRef);
    if (ledgerEntry.exists) {
      throw new HttpsError("already-exists", "This ride is already in the ledger.");
    }
    transaction.update(rideRef, {
      status: "completed",
      endTime: FieldValue.serverTimestamp(),
      finalPrice: finalFare,
      currency: "PHP",
      fareBasis: "base_plus_distance",
      paymentMethod: "cash",
      cashCollectedByDriver: true,
    });
    transaction.create(ledgerRef, {
      rideId,
      passengerId,
      driverId: request.auth!.uid,
      currency: "PHP",
      farePhp: finalFare,
      baseFarePhp: BASE_FARE_PHP,
      distanceKm,
      ratePerKmPhp: FARE_PER_KILOMETER_PHP,
      driverFareAllocationPhp: driverAllocation,
      cooperativeFeePhp: cooperativeFee,
      cooperativeSharePercent: COOPERATIVE_SHARE_PERCENT,
      allocationPolicyVersion: FARE_ALLOCATION_POLICY_VERSION,
      driverCreditPhp: 0,
      cashFarePhp: finalFare,
      platformCreditPhp: 0,
      fareBasis: "base_plus_distance",
      fareCalculationVersion: "php_base15_per_km8_v1",
      entryType: "cash_fare_record",
      paymentMethod: "cash",
      cashCollectedByDriver: true,
      settlementStatus: "cash_recorded",
      createdAt: FieldValue.serverTimestamp(),
    });
    if (presence.exists && presence.get("activeRideId") === rideId) {
      transaction.update(presenceRef, {
        activeRideId: null,
        isOnline: false,
        updatedAt: FieldValue.serverTimestamp(),
      });
    }
    if (activeRide.exists && activeRide.get("rideId") === rideId) {
      transaction.delete(activeRideRef);
    }
  });
  if (passengerIdForNotification) {
    await notifyUser(
      passengerIdForNotification,
      "Ride completed",
      `Your ride is complete. Recorded cash fare: PHP ${finalFare.toFixed(2)}.`,
      { type: "ride_completed", rideId },
    );
  }
  return {
    completed: true,
    farePhp: finalFare,
    paymentMethod: "cash",
    cashCollectedByDriver: true,
    platformCreditPhp: 0,
    currency: "PHP",
    settlementStatus: "cash_recorded",
  };
});

export const issueTripVerificationCode = onCall(callableOptions, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in to verify a trip.");
  }
  await requireRole(request.auth.uid, "passenger");
  const rideId = request.data?.rideId;
  if (typeof rideId !== "string" || rideId.length === 0) {
    throw new HttpsError("invalid-argument", "rideId is required.");
  }

  const rideRef = db.collection("rides").doc(rideId);
  const code = randomBytes(32).toString("hex");
  const expiresAt = Timestamp.fromMillis(Date.now() + TRIP_QR_TTL_MS);
  await db.runTransaction(async (transaction) => {
    const ride = await transaction.get(rideRef);
    if (
      !ride.exists ||
      ride.get("passengerId") !== request.auth!.uid ||
      !["accepted", "in_progress"].includes(ride.get("status"))
    ) {
      throw new HttpsError(
        "failed-precondition",
        "A QR code is available only for your accepted ride.",
      );
    }
    transaction.update(rideRef, {
      tripVerificationCodeHash: createHash("sha256").update(code).digest("hex"),
      tripVerificationExpiresAt: expiresAt,
    });
  });
  return { code, expiresAt: expiresAt.toDate().toISOString() };
});

export const startRide = onCall(callableOptions, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in to start a ride.");
  }
  await requireRole(request.auth.uid, "driver");
  throw new HttpsError(
    "failed-precondition",
    "A passenger QR scan is required to start this ride.",
  );
});

export const verifyPassengerTripQr = onCall(callableOptions, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in to verify a trip.");
  }
  await requireRole(request.auth.uid, "driver");
  const rideId = request.data?.rideId;
  const code = request.data?.code;
  if (
    typeof rideId !== "string" ||
    rideId.length === 0 ||
    typeof code !== "string" ||
    !/^[a-f0-9]{64}$/.test(code)
  ) {
    throw new HttpsError("invalid-argument", "The trip QR code is invalid.");
  }

  const rideRef = db.collection("rides").doc(rideId);
  const presenceRef = db.collection("driver_presence").doc(request.auth.uid);
  const codeHash = createHash("sha256").update(code).digest("hex");
  await db.runTransaction(async (transaction) => {
    const ride = await transaction.get(rideRef);
    const presence = await transaction.get(presenceRef);
    if (
      !ride.exists ||
      ride.get("driverId") !== request.auth!.uid ||
      ride.get("status") !== "accepted" ||
      ride.get("tripVerificationCodeHash") !== codeHash
    ) {
      throw new HttpsError(
        "failed-precondition",
        "This trip QR code is invalid or has already been used.",
      );
    }

    const expiresAt = ride.get("tripVerificationExpiresAt");
    if (!(expiresAt instanceof Timestamp) || expiresAt.toMillis() <= Date.now()) {
      throw new HttpsError("deadline-exceeded", "This trip QR code has expired.");
    }
    if (
      !presence.exists ||
      presence.get("activeRideId") !== rideId ||
      !(presence.get("location") instanceof GeoPoint)
    ) {
      throw new HttpsError(
        "failed-precondition",
        "Current driver location is unavailable.",
      );
    }

    const location = presence.get("location") as GeoPoint;
    const updatedAt = presence.get("updatedAt");
    const accuracyMeters = presence.get("locationAccuracyMeters");
    if (
      !(updatedAt instanceof Timestamp) ||
      Date.now() - updatedAt.toMillis() > DRIVER_LOCATION_MAX_AGE_MS ||
      typeof accuracyMeters !== "number" ||
      accuracyMeters > MAX_LOCATION_ACCURACY_METERS
    ) {
      throw new HttpsError(
        "failed-precondition",
        "Refresh your accurate location before verifying the passenger.",
      );
    }
    if (
      distanceKm(
        { latitude: location.latitude, longitude: location.longitude },
        { latitude: ride.get("pickupLat"), longitude: ride.get("pickupLng") },
      ) > MAX_START_DISTANCE_FROM_PICKUP_KM
    ) {
      throw new HttpsError(
        "failed-precondition",
        "Move within 500 meters of the pickup before starting the trip.",
      );
    }

    transaction.update(rideRef, {
      status: "in_progress",
      startTime: FieldValue.serverTimestamp(),
      qrValidatedAt: FieldValue.serverTimestamp(),
      tripVerificationCodeHash: FieldValue.delete(),
      tripVerificationExpiresAt: FieldValue.delete(),
    });
  });
  return { verified: true, started: true };
});

export const getAdminRideReport = onCall(callableOptions, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in to view ride reports.");
  }
  await requireAdmin(request.auth.uid);

  const now = Date.now();
  const cutoff = Timestamp.fromMillis(now - 30 * 24 * 60 * 60 * 1000);
  const forecastCutoff = Timestamp.fromMillis(
    now - 35 * 24 * 60 * 60 * 1000,
  );
  const snapshot = await db
    .collection("rides")
    .where("createdAt", ">=", forecastCutoff)
    .orderBy("createdAt", "desc")
    .limit(MAX_REPORT_RIDES)
    .get();
  const reportRides = snapshot.docs.filter((document) => {
    const createdAt = document.get("createdAt");
    return createdAt instanceof Timestamp && createdAt.toMillis() >= cutoff.toMillis();
  });
  const rides = reportRides.map((document) => {
    const data = document.data();
    const createdAt = data.createdAt;
    return {
      rideId: document.id,
      status: data.status ?? "unknown",
      pickupLocation: data.pickupLocation ?? "",
      dropoffLocation: data.dropoffLocation ?? "",
      farePhp: typeof data.finalPrice === "number" ? data.finalPrice : null,
      distanceKm:
        typeof data.distance === "number" ? data.distance : null,
      createdAt:
        createdAt instanceof Timestamp ? createdAt.toDate().toISOString() : null,
      paymentMethod: data.paymentMethod ?? null,
    };
  });
  const counts: Record<string, number> = {};
  let completedCashFarePhp = 0;
  const ridesByDate: Record<string, number> = {};
  let completedDistanceKm = 0;
  let completedDistanceSamples = 0;
  for (const ride of rides) {
    counts[ride.status] = (counts[ride.status] ?? 0) + 1;
    if (ride.createdAt) {
      const day = ride.createdAt.slice(0, 10);
      ridesByDate[day] = (ridesByDate[day] ?? 0) + 1;
    }
    if (
      ride.status === "completed" &&
      ride.paymentMethod === "cash" &&
      typeof ride.farePhp === "number"
    ) {
      completedCashFarePhp += ride.farePhp;
    }
    if (ride.status === "completed" && typeof ride.distanceKm === "number") {
      completedDistanceKm += ride.distanceKm;
      completedDistanceSamples += 1;
    }
  }

  const targetHour = new Date(now + 60 * 60 * 1000);
  const historicalHours = snapshot.docs.filter((document) => {
    const createdAt = document.get("createdAt");
    if (!(createdAt instanceof Timestamp)) return false;
    const date = createdAt.toDate();
    return (
      date.getUTCDay() === targetHour.getUTCDay() &&
      date.getUTCHours() === targetHour.getUTCHours() &&
      date.getTime() < now
    );
  });
  const sampleDates: string[] = [];
  for (let daysAgo = 1; daysAgo <= 35; daysAgo += 1) {
    const sample = new Date(targetHour.getTime() - daysAgo * 24 * 60 * 60 * 1000);
    if (
      sample.getTime() < now &&
      sample.getUTCDay() === targetHour.getUTCDay() &&
      sample.getUTCHours() === targetHour.getUTCHours()
    ) {
      sampleDates.push(
        `${sample.getUTCFullYear()}-${sample.getUTCMonth()}-${sample.getUTCDate()}`,
      );
    }
  }
  const requestCountsBySample: Record<string, number> = {};
  for (const document of historicalHours) {
    const date = (document.get("createdAt") as Timestamp).toDate();
    const key = `${date.getUTCFullYear()}-${date.getUTCMonth()}-${date.getUTCDate()}`;
    requestCountsBySample[key] = (requestCountsBySample[key] ?? 0) + 1;
  }
  const sampledRequests = sampleDates.reduce(
    (total, sampleDate) => total + (requestCountsBySample[sampleDate] ?? 0),
    0,
  );
  const sampledWeeks = sampleDates.length;
  const demandAverage =
    sampledWeeks > 0 ? sampledRequests / sampledWeeks : 0;
  const demandLevel =
    demandAverage >= 3 ? "high" : demandAverage >= 1 ? "moderate" : "low";

  return {
    periodDays: 30,
    totalRides: rides.length,
    completedCashFarePhp,
    averageCompletedDistanceKm:
      completedDistanceSamples > 0
        ? completedDistanceKm / completedDistanceSamples
        : 0,
    ridesByDate,
    demandForecast: {
      nextHourUtc: targetHour.toISOString(),
      averageRequestsPerHour: demandAverage,
      matchingHistoricalHours: sampledWeeks,
      level: demandLevel,
      method: "average of matching weekday/hour buckets from recent 35-day history",
    },
    counts,
    capped: snapshot.size === MAX_REPORT_RIDES,
    recentRides: rides.slice(0, 50),
  };
});

export const acceptRide = onCall(callableOptions, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in to accept a ride.");
  }
  await requireRole(request.auth.uid, "driver");
  const rideId = request.data?.rideId;
  if (typeof rideId !== "string" || rideId.length === 0) {
    throw new HttpsError("invalid-argument", "rideId is required.");
  }

  const rideRef = db.collection("rides").doc(rideId);
  const presenceRef = db.collection("driver_presence").doc(request.auth.uid);
  let passengerIdForNotification: string | null = null;
  await db.runTransaction(async (transaction) => {
    const ride = await transaction.get(rideRef);
    const presence = await transaction.get(presenceRef);
    const oldestWaitingRide = await transaction.get(
      db.collection("rides")
        .where("status", "==", "requested")
        .orderBy("createdAt")
        .limit(1),
    );
    if (
      !ride.exists ||
      ride.get("status") !== "requested" ||
      !presence.exists ||
      presence.get("isOnline") !== true ||
      presence.get("activeRideId")
    ) {
      throw new HttpsError("failed-precondition", "This ride is no longer available.");
    }
    if (oldestWaitingRide.docs[0]?.id !== rideId) {
      throw new HttpsError(
        "failed-precondition",
        "Earlier ride requests must be dispatched first.",
      );
    }
    const passengerId = ride.get("passengerId");
    if (typeof passengerId !== "string") {
      throw new HttpsError("failed-precondition", "Ride passenger is invalid.");
    }
    passengerIdForNotification = passengerId;
    const passengerActiveRef = db.collection("passenger_active").doc(passengerId);
    const passengerActive = await transaction.get(passengerActiveRef);
    if (passengerActive.exists) {
      throw new HttpsError("failed-precondition", "Passenger already has an active ride.");
    }

    const location = presence.get("location");
    const updatedAt = presence.get("updatedAt");
    const accuracyMeters = presence.get("locationAccuracyMeters");
    if (
      !(location instanceof GeoPoint) ||
      !(updatedAt instanceof Timestamp) ||
      Date.now() - updatedAt.toMillis() > DRIVER_LOCATION_MAX_AGE_MS ||
      typeof accuracyMeters !== "number" ||
      accuracyMeters > MAX_LOCATION_ACCURACY_METERS
    ) {
      throw new HttpsError("failed-precondition", "Driver location is stale.");
    }
    const pickupLatitude = ride.get("pickupLat");
    const pickupLongitude = ride.get("pickupLng");
    if (
      typeof pickupLatitude !== "number" ||
      typeof pickupLongitude !== "number" ||
      distanceKm(
        { latitude: location.latitude, longitude: location.longitude },
        { latitude: pickupLatitude, longitude: pickupLongitude },
      ) > MAX_MATCH_DISTANCE_KM
    ) {
      throw new HttpsError(
        "failed-precondition",
        "This ride is outside the driver's 5 km dispatch range.",
      );
    }
    transaction.update(rideRef, {
      driverId: request.auth!.uid,
      driverLocation: location,
      driverLocationAccuracyMeters: accuracyMeters,
      driverLocationUpdatedAt: updatedAt,
      status: "accepted",
      dispatchState: "assigned",
    });
    transaction.update(presenceRef, {
      isOnline: false,
      activeRideId: rideId,
      updatedAt: FieldValue.serverTimestamp(),
    });
    transaction.create(passengerActiveRef, { rideId });
  });
  if (passengerIdForNotification) {
    await notifyUser(
      passengerIdForNotification,
      "Driver accepted your ride",
      "A driver has accepted your queued ride request.",
      { type: "ride_assigned", rideId },
    );
  }
  return { accepted: true };
});

export const cancelRide = onCall(callableOptions, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in to cancel a ride.");
  }
  await requireRole(request.auth.uid, "passenger");
  const rideId = request.data?.rideId;
  if (typeof rideId !== "string" || rideId.length === 0) {
    throw new HttpsError("invalid-argument", "rideId is required.");
  }
  const rideRef = db.collection("rides").doc(rideId);
  let driverIdForNotification: string | null = null;

  await db.runTransaction(async (transaction) => {
    const ride = await transaction.get(rideRef);
    if (
      !ride.exists ||
      ride.get("passengerId") !== request.auth!.uid ||
      !["requested", "accepted"].includes(ride.get("status"))
    ) {
      throw new HttpsError("failed-precondition", "Ride cannot be cancelled.");
    }
    const driverId = ride.get("driverId");
    driverIdForNotification =
      typeof driverId === "string" ? driverId : null;
    const presenceRef =
      typeof driverId === "string"
        ? db.collection("driver_presence").doc(driverId)
        : null;
    const presence = presenceRef
      ? await transaction.get(presenceRef)
      : null;
    const activeRideRef = db.collection("passenger_active").doc(request.auth!.uid);
    const activeRide = await transaction.get(activeRideRef);

    transaction.update(rideRef, {
      status: "cancelled",
    });
    if (presence?.exists && presence.get("activeRideId") === rideId) {
      transaction.update(presenceRef!, {
        activeRideId: null,
        isOnline: false,
        updatedAt: FieldValue.serverTimestamp(),
      });
    }
    if (activeRide.exists && activeRide.get("rideId") === rideId) {
      transaction.delete(activeRideRef);
    }
  });
  if (driverIdForNotification) {
    await notifyUser(
      driverIdForNotification,
      "Ride cancelled",
      "The passenger cancelled this ride.",
      { type: "ride_cancelled", rideId },
    );
  }
  return { cancelled: true };
});
