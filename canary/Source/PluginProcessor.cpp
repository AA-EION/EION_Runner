#include "PluginProcessor.h"
#include "PluginEditor.h"

CanaryAudioProcessor::CanaryAudioProcessor()
    : juce::AudioProcessor (BusesProperties()
                                .withInput  ("Input",  juce::AudioChannelSet::stereo(), true)
                                .withOutput ("Output", juce::AudioChannelSet::stereo(), true)),
      parameters (*this, nullptr, juce::Identifier ("Canary"), createParameterLayout())
{
    gainParam   = parameters.getRawParameterValue (gainParamId);
    cutoffParam = parameters.getRawParameterValue (cutoffParamId);
}

juce::AudioProcessorValueTreeState::ParameterLayout CanaryAudioProcessor::createParameterLayout()
{
    juce::AudioProcessorValueTreeState::ParameterLayout layout;

    layout.add (std::make_unique<juce::AudioParameterFloat> (
        juce::ParameterID { gainParamId, 1 },
        "Gain",
        juce::NormalisableRange<float> (0.0f, 2.0f, 0.0001f),
        0.8f));

    layout.add (std::make_unique<juce::AudioParameterFloat> (
        juce::ParameterID { cutoffParamId, 1 },
        "Cutoff",
        juce::NormalisableRange<float> (20.0f, 20000.0f, 1.0f, 0.3f),
        8000.0f));

    return layout;
}

void CanaryAudioProcessor::prepareToPlay (double sampleRate, int)
{
    dsp.prepare (sampleRate);
}

void CanaryAudioProcessor::releaseResources()
{
    dsp.reset();
}

bool CanaryAudioProcessor::isBusesLayoutSupported (const BusesLayout& layouts) const
{
    const auto& out = layouts.getMainOutputChannelSet();

    if (out != juce::AudioChannelSet::mono() && out != juce::AudioChannelSet::stereo())
        return false;

    // An effect must not change the channel count between input and output.
    return layouts.getMainInputChannelSet() == out;
}

void CanaryAudioProcessor::processBlock (juce::AudioBuffer<float>& buffer, juce::MidiBuffer&)
{
    juce::ScopedNoDenormals noDenormals;

    const auto numChannels = buffer.getNumChannels();
    const auto numSamples  = buffer.getNumSamples();

    // Clear any output channel the host gave us that has no matching input.
    for (auto ch = getTotalNumInputChannels(); ch < getTotalNumOutputChannels(); ++ch)
        buffer.clear (ch, 0, numSamples);

    dsp.setGain (gainParam   != nullptr ? gainParam->load()   : 0.8f);
    dsp.setCutoffHz (cutoffParam != nullptr ? cutoffParam->load() : 8000.0f);

    for (int ch = 0; ch < juce::jmin (numChannels, CanaryDsp::maxChannels); ++ch)
    {
        auto* samples = buffer.getWritePointer (ch);

        for (int i = 0; i < numSamples; ++i)
            samples[i] = dsp.processSample (ch, samples[i]);
    }
}

juce::AudioProcessorEditor* CanaryAudioProcessor::createEditor()
{
    return new CanaryAudioProcessorEditor (*this);
}

void CanaryAudioProcessor::getStateInformation (juce::MemoryBlock& destData)
{
    if (auto xml = parameters.copyState().createXml())
        copyXmlToBinary (*xml, destData);
}

void CanaryAudioProcessor::setStateInformation (const void* data, int sizeInBytes)
{
    if (auto xml = getXmlFromBinary (data, sizeInBytes))
        if (xml->hasTagName (parameters.state.getType()))
            parameters.replaceState (juce::ValueTree::fromXml (*xml));
}

// The entry point every JUCE plugin format wrapper calls.
juce::AudioProcessor* JUCE_CALLTYPE createPluginFilter()
{
    return new CanaryAudioProcessor();
}
