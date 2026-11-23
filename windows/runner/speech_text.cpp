#include "speech_text.h"

#include <flutter/standard_method_codec.h>
#include <sapi.h>
#include <windows.h>

#include <string>

namespace {

// Flutter gives UTF-8; SAPI wants UTF-16.
std::wstring Widen(const std::string& utf8) {
  if (utf8.empty()) return std::wstring();
  const int size = ::MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(),
                                         static_cast<int>(utf8.size()),
                                         nullptr, 0);
  if (size <= 0) return std::wstring();
  std::wstring wide(static_cast<size_t>(size), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(),
                        static_cast<int>(utf8.size()), wide.data(), size);
  return wide;
}

}  // namespace

SpeechText::SpeechText(flutter::BinaryMessenger* messenger) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "verbal_outlet/speech",
      &flutter::StandardMethodCodec::GetInstance());

  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        HandleMethodCall(call, std::move(result));
      });
}

SpeechText::~SpeechText() {
  if (voice_ != nullptr) {
    static_cast<ISpVoice*>(voice_)->Release();
    voice_ = nullptr;
  }
}

void SpeechText::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() == "stop") {
    if (voice_ != nullptr) {
      // 2 = SPF_PURGEBEFORESPEAK, which drops anything still queued.
      static_cast<ISpVoice*>(voice_)->Speak(L"", 2, nullptr);
    }
    result->Success();
    return;
  }

  if (call.method_name() != "speak") {
    result->NotImplemented();
    return;
  }

  const auto* arguments = std::get_if<flutter::EncodableMap>(call.arguments());
  if (arguments == nullptr) {
    result->Success(flutter::EncodableValue(false));
    return;
  }

  auto text_it = arguments->find(flutter::EncodableValue("text"));
  if (text_it == arguments->end()) {
    result->Success(flutter::EncodableValue(false));
    return;
  }
  const auto* text = std::get_if<std::string>(&text_it->second);
  if (text == nullptr || text->empty()) {
    result->Success(flutter::EncodableValue(false));
    return;
  }

  if (voice_ == nullptr) {
    ISpVoice* voice = nullptr;
    const HRESULT created =
        ::CoCreateInstance(CLSID_SpVoice, nullptr, CLSCTX_ALL, IID_ISpVoice,
                           reinterpret_cast<void**>(&voice));
    if (FAILED(created) || voice == nullptr) {
      // No speech engine: the question is still on screen, so this is not an
      // error worth failing the call over.
      result->Success(flutter::EncodableValue(false));
      return;
    }
    voice_ = voice;
  }

  // 1 = SPF_ASYNC, so the caller is not blocked while the sentence is spoken.
  // 2 = SPF_PURGEBEFORESPEAK, so a new question replaces the previous one
  // rather than queueing behind it.
  const std::wstring wide = Widen(*text);
  const HRESULT spoken =
      static_cast<ISpVoice*>(voice_)->Speak(wide.c_str(), 1 | 2, nullptr);
  result->Success(flutter::EncodableValue(SUCCEEDED(spoken)));
}
