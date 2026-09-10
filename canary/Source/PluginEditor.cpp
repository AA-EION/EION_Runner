#include "PluginEditor.h"

namespace
{
    constexpr int editorWidth  = 380;
    constexpr int editorHeight = 220;
    constexpr int rowHeight    = 48;
    constexpr int margin       = 16;
    constexpr int labelWidth   = 90;
}

CanaryAudioProcessorEditor::CanaryAudioProcessorEditor (CanaryAudioProcessor& owner)
    : juce::AudioProcessorEditor (&owner), processorRef (owner)
{
    titleLabel.setText ("Canary", juce::dontSendNotification);
    titleLabel.setJustificationType (juce::Justification::centred);
    titleLabel.setFont (juce::FontOptions (24.0f, juce::Font::bold));
    addAndMakeVisible (titleLabel);

    gainLabel.setText ("Gain", juce::dontSendNotification);
    gainLabel.setJustificationType (juce::Justification::centredLeft);
    addAndMakeVisible (gainLabel);

    cutoffLabel.setText ("Cutoff", juce::dontSendNotification);
    cutoffLabel.setJustificationType (juce::Justification::centredLeft);
    addAndMakeVisible (cutoffLabel);

    gainSlider.setSliderStyle (juce::Slider::LinearHorizontal);
    gainSlider.setTextBoxStyle (juce::Slider::TextBoxRight, false, 72, 22);
    addAndMakeVisible (gainSlider);

    cutoffSlider.setSliderStyle (juce::Slider::LinearHorizontal);
    cutoffSlider.setTextBoxStyle (juce::Slider::TextBoxRight, false, 72, 22);
    cutoffSlider.setTextValueSuffix (" Hz");
    addAndMakeVisible (cutoffSlider);

    auto& state = processorRef.getValueTreeState();
    gainAttachment   = std::make_unique<SliderAttachment> (state, CanaryAudioProcessor::gainParamId,   gainSlider);
    cutoffAttachment = std::make_unique<SliderAttachment> (state, CanaryAudioProcessor::cutoffParamId, cutoffSlider);

    setSize (editorWidth, editorHeight);
}

void CanaryAudioProcessorEditor::paint (juce::Graphics& g)
{
    g.fillAll (getLookAndFeel().findColour (juce::ResizableWindow::backgroundColourId));
}

void CanaryAudioProcessorEditor::resized()
{
    auto area = getLocalBounds().reduced (margin);

    titleLabel.setBounds (area.removeFromTop (rowHeight));
    area.removeFromTop (margin);

    auto gainRow = area.removeFromTop (rowHeight);
    gainLabel.setBounds (gainRow.removeFromLeft (labelWidth));
    gainSlider.setBounds (gainRow);

    area.removeFromTop (margin / 2);

    auto cutoffRow = area.removeFromTop (rowHeight);
    cutoffLabel.setBounds (cutoffRow.removeFromLeft (labelWidth));
    cutoffSlider.setBounds (cutoffRow);
}
