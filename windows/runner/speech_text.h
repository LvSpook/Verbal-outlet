#ifndef RUNNER_SPEECH_TEXT_H_
#define RUNNER_SPEECH_TEXT_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>
#include <string>

// Reads text aloud with the Windows speech engine (SAPI).
//
// A channel handler rather than a plugin: the app only needs "say this" and
// "stop", and both platforms already have a speech engine built in. This keeps
// the Windows build free of extra toolchain requirements.
class SpeechText {
 public:
  explicit SpeechText(flutter::BinaryMessenger* messenger);
  ~SpeechText();

  SpeechText(const SpeechText&) = delete;
  SpeechText& operator=(const SpeechText&) = delete;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // COM is initialised on the platform thread by the runner, which is where
  // SAPI objects are created and used.
  void* voice_ = nullptr;  // ISpVoice*, kept void* to avoid a global COM header
  void* stream_ = nullptr;  // IStream* for the memory buffer, when speaking

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_SPEECH_TEXT_H_
