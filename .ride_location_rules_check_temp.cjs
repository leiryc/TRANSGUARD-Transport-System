const fs = require('node:fs');
const {
  initializeTestEnvironment,
  assertSucceeds,
} = require('@firebase/rules-unit-testing');
const {
  doc,
  GeoPoint,
  getDoc,
  serverTimestamp,
  setDoc,
  updateDoc,
} = require('firebase/firestore');

async function main() {
  const testEnv = await initializeTestEnvironment({
    projectId: 'demo-transguard-rules',
    firestore: { rules: fs.readFileSync('firestore.rules', 'utf8') },
  });

  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await setDoc(doc(db, 'users', 'driver-test'), { userType: 'driver' });
    await setDoc(doc(db, 'rides', 'ride-test'), {
      passengerId: 'passenger-test',
      driverId: 'driver-test',
      status: 'accepted',
    });
  });

  const driverDb = testEnv.authenticatedContext('driver-test').firestore();
  await assertSucceeds(
    updateDoc(doc(driverDb, 'rides', 'ride-test'), {
      driverLocation: new GeoPoint(14, 121),
      driverLocationAccuracyMeters: 100,
      driverLocationUpdatedAt: serverTimestamp(),
    }),
  );

  const passengerDb = testEnv
    .authenticatedContext('passenger-test')
    .firestore();
  await assertSucceeds(getDoc(doc(passengerDb, 'rides', 'ride-test')));
  console.log('PASS: driver location update and passenger ride read are allowed');
  await testEnv.cleanup();
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
