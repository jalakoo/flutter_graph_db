void syncWarn(String message) {
  // Web has no stderr; surface via print so it shows in the JS
  // console.
  // ignore: avoid_print
  print(message);
}
