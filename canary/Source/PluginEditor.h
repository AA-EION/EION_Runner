#pragma once

#include <juce_audio_processors/juce_audio_processors.h>
#include <juce_gui_basics/juce_gui_basics.h>

#include "PluginProcessor.h"

#include <memory>

/**
    A deliberately plain editor: two sliders and a title.

    It exists because a plugin without an editor is not a realistic test of the
    build — the GUI modules are a large part of what has to compile and link on
    every platform, and they are where cross-platform builds usually break
    first.
*/
class CanaryAudioProcessorEditor final : public juce::AudioProcessorEditor
{
public:
    explicit CanaryAudioProcessorEditor (CanaryAudioProcessor&);
    ~CanaryAudioProcessorEditor() override = default;

    void paint (juce::Graphics&) override;
    void resized() override;

private:
    using SliderAttachment = juce::AudioProcessorValueTreeState::SliderAttachment;

    CanaryAudioProcessor& processorRef;

    juce::Label  titleLabel;
    juce::Label  gainLabel;
    juce::Label  cutoffLabel;
    juce::Slider gainSlider;
    juce::Slider cutoffSlider;

    std::unique_ptr<SliderAttachment> gainAttachment;
    std::unique_ptr<SliderAttachment> cutoffAttachment;

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR (CanaryAudioProcessorEditor)
};
