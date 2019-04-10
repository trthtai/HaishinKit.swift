import AVFoundation
import AudioKit

final class AudioIOComponent: IOComponent {
	lazy var encoder = AudioConverter()
	let lockQueue = DispatchQueue(label: "com.haishinkit.HaishinKit.AudioIOComponent.lock")
	
	var audioEngine: AVAudioEngine?
	
	var delay: AKVariableDelay!
	var delayMixer: AKDryWetMixer!
	var reverb: AKCostelloReverb!
	var reverbMixer: AKDryWetMixer!
	var booster: AKBooster!
	
	var soundTransform: SoundTransform = .init() {
		didSet {
			soundTransform.apply(playerNode)
		}
	}
	
	private var _playerNode: AVAudioPlayerNode?
	private var playerNode: AVAudioPlayerNode! {
		get {
			if _playerNode == nil {
				_playerNode = AVAudioPlayerNode()
				audioEngine?.attach(_playerNode!)
			}
			return _playerNode
		}
		set {
			if let playerNode = _playerNode {
				audioEngine?.detach(playerNode)
			}
			_playerNode = newValue
		}
	}
	
	private var audioFormat: AVAudioFormat? {
		didSet {
			guard let audioFormat = audioFormat, let audioEngine = audioEngine else {
				return
			}
			
			nstry({
				audioEngine.connect(self.playerNode, to: audioEngine.outputNode, format: audioFormat)
			}, { exeption in
				logger.warn(exeption)
			})
			do {
				try audioEngine.start()
			} catch {
				logger.warn(error)
			}
		}
	}
	
	#if os(iOS) || os(macOS)
	var input: AKStereoInput = AKStereoInput()
	//    var input: AVCaptureDeviceInput? {
	//        didSet {
	//            guard let mixer: AVMixer = mixer, oldValue != input else {
	//                return
	//            }
	//            if let oldValue: AVCaptureDeviceInput = oldValue {
	//                mixer.session.removeInput(oldValue)
	//            }
	//            if let input: AVCaptureDeviceInput = input, mixer.session.canAddInput(input) {
	//                mixer.session.addInput(input)
	//            }
	//        }
	//    }
	//
	private var _output: AVCaptureAudioDataOutput?
	var output: AVCaptureAudioDataOutput! {
		get {
			if _output == nil {
				_output = AVCaptureAudioDataOutput()
			}
			return _output
		}
		set {
			if _output == newValue {
				return
			}
			if let output: AVCaptureAudioDataOutput = _output {
				output.setSampleBufferDelegate(nil, queue: nil)
				mixer?.session.removeOutput(output)
			}
			_output = newValue
		}
	}
	#endif
	
	override init(mixer: AVMixer) {
		super.init(mixer: mixer)
		encoder.lockQueue = lockQueue
	}
	
	func appendSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
		mixer?.recorder.appendSampleBuffer(sampleBuffer, mediaType: .audio)
		encoder.encodeSampleBuffer(sampleBuffer)
	}
	
	#if os(iOS) || os(macOS)
	func attachAudio(_ audio: AVCaptureDevice?, automaticallyConfiguresApplicationAudioSession: Bool) throws {
		guard let mixer: AVMixer = mixer else {
			return
		}
		
		mixer.session.beginConfiguration()
		defer {
			mixer.session.commitConfiguration()
		}
		
		//        output = nil
		do {
			try AudioKit.stop()
		} catch {
			AKLog("AudioKit did not stop!")
		}
		encoder.invalidate()
		
		//        guard let audio: AVCaptureDevice = audio else {
		//            input = nil
		//            return
		//        }
		
		//        input = try AVCaptureDeviceInput(device: audio)
		//        #if os(iOS)
		//        mixer.session.automaticallyConfiguresApplicationAudioSession = automaticallyConfiguresApplicationAudioSession
		//        #endif
		delay = AKVariableDelay(self.input)
		delay.rampDuration = 0.5 // Allows for some cool effects
		delay.time = 0.5
		delay.feedback = 0.5
		delayMixer = AKDryWetMixer(self.input, delay)
		
		reverb = AKCostelloReverb(delayMixer)
		reverbMixer = AKDryWetMixer(delayMixer, reverb)
		
		booster = AKBooster(reverbMixer)
		booster.avAudioNode.installTap(onBus: 0, bufferSize: AKSettings.bufferLength.samplesCount, format: nil) { (buffer, _) in
			let sampleBuffer = self.createAudioSampleBufferFrom(pcmBuffer: buffer)
			self.appendSampleBuffer(sampleBuffer!)
		}
		
		mixer.session.addOutput(output)
		output.setSampleBufferDelegate(self, queue: lockQueue)
		
		AudioKit.output = booster
		do {
			try AudioKit.start()
		} catch {
			AKLog("AudioKit did not start!")
		}
	}
	
	func createAudioSampleBufferFrom(pcmBuffer: AVAudioPCMBuffer) -> CMSampleBuffer? {
		let audioBufferList = pcmBuffer.audioBufferList
		let audioStreamBasicDescription = pcmBuffer.format.streamDescription
		let framesCount: UInt32 = pcmBuffer.frameLength
		
		var sampleBuffer: CMSampleBuffer? = nil
		var status: OSStatus = -1
		var format: CMFormatDescription? = nil
		
		status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: audioStreamBasicDescription, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
		guard status == noErr else {
			return nil
		}
		
		var formatdes: CMFormatDescription? = nil
		status = CMFormatDescriptionCreate(allocator: nil, mediaType: kCMMediaType_Audio, mediaSubType: self.fourCharCode(from: "lpcm"), extensions: nil, formatDescriptionOut: &formatdes)
		guard status == noErr else {
			return nil
		}
		
		var timing: CMSampleTimingInfo = CMSampleTimingInfo(duration: CMTimeMake(value: 1, timescale: 44100), presentationTimeStamp: CMTime.zero, decodeTimeStamp: CMTime.invalid)
		status = CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil, formatDescription: format, sampleCount: CMItemCount(framesCount), sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer)
		guard status == noErr else {
			return nil
		}
		
		status = CMSampleBufferSetDataBufferFromAudioBufferList(sampleBuffer!, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: audioBufferList)
		guard status == noErr else {
			return nil
		}
		
		return sampleBuffer!
	}
	
	func fourCharCode(from string : String) -> FourCharCode
	{
		return string.utf16.reduce(0, {$0 << 8 + FourCharCode($1)})
	}
	
	func dispose() {
		//        input = nil
		//        output = nil
		playerNode = nil
		audioFormat = nil
		
		do {
			try AudioKit.stop()
		} catch {
			AKLog("AudioKit did not stop!")
		}
	}
	#else
	func dispose() {
		playerNode = nil
		audioFormat = nil
	}
	#endif
}

extension AudioIOComponent: AVCaptureAudioDataOutputSampleBufferDelegate {
	// MARK: AVCaptureAudioDataOutputSampleBufferDelegate
	func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
		appendSampleBuffer(sampleBuffer)
	}
}

extension AudioIOComponent: AudioConverterDelegate {
	// MARK: AudioConverterDelegate
	func didSetFormatDescription(audio formatDescription: CMFormatDescription?) {
		guard let formatDescription = formatDescription else { return }
		#if os(iOS)
		if #available(iOS 9.0, *) {
			audioFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)
		} else {
			guard let asbd = formatDescription.streamBasicDescription?.pointee else {
				return
			}
			audioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: asbd.mSampleRate, channels: asbd.mChannelsPerFrame, interleaved: false)
		}
		#else
		audioFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)
		#endif
	}
	
	func sampleOutput(audio data: UnsafeMutableAudioBufferListPointer, presentationTimeStamp: CMTime) {
		guard !data.isEmpty else { return }
		
		guard
			let audioFormat = audioFormat,
			let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: data[0].mDataByteSize / 4) else {
				return
		}
		
		buffer.frameLength = buffer.frameCapacity
		let bufferList = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
		for i in 0..<bufferList.count {
			guard let mData = data[i].mData else { continue }
			memcpy(bufferList[i].mData, mData, Int(data[i].mDataByteSize))
			bufferList[i].mDataByteSize = data[i].mDataByteSize
			bufferList[i].mNumberChannels = 1
		}
		
		nstry({
			self.playerNode.scheduleBuffer(buffer, completionHandler: nil)
			if !self.playerNode.isPlaying {
				self.playerNode.play()
			}
		}, { exeption in
			logger.warn("\(exeption)")
		})
	}
}
