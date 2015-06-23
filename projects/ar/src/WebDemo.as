package {
	
	import flash.events.Event;
	import flash.events.IOErrorEvent;
	import flash.events.SecurityErrorEvent;
	import flash.events.NetStatusEvent;
	import flash.events.KeyboardEvent;
	
	import org.papervision3d.lights.PointLight3D;
	
	import org.papervision3d.core.proto.MaterialObject3D;
	import org.papervision3d.materials.WireframeMaterial;
	import org.papervision3d.materials.ColorMaterial;
	import org.papervision3d.materials.BitmapFileMaterial;
	import org.papervision3d.materials.VideoStreamMaterial;
	import org.papervision3d.materials.special.CompositeMaterial;
	import org.papervision3d.materials.utils.MaterialsList;
	
	import org.papervision3d.objects.DisplayObject3D;
	import org.papervision3d.objects.primitives.Sphere;
	import org.papervision3d.objects.primitives.Cube;
	import org.papervision3d.objects.primitives.Plane;
	import org.papervision3d.objects.parsers.Collada;
	import org.papervision3d.objects.parsers.DAE;
	
	import org.papervision3d.events.FileLoadEvent;
	
	import flash.display.LoaderInfo;
	
	import flash.net.URLLoader;
	import flash.net.URLLoaderDataFormat;
	import flash.net.URLRequest;
	
	import flash.net.NetConnection;
	import flash.net.NetStream;
	import flash.media.Video;
	
	import flash.media.SoundTransform;
	
	import flash.ui.Keyboard;
	
	import com.autofuss.ar.multi.PV3DARApp_MultiResPer;
	
	public class WebDemo extends PV3DARApp_MultiResPer{
		
		private static const CAMERA_FILE:String = "Camera/camera_para.dat";		//Camera calibration file
		
		// Read locations from FlashVars to make it flexible
		private var baseURL:String;				// The web address and project folder
		private var patternsLocation:String;	// The XML file that contains the information on the pattern codes
		
		// Stuff for reading in display information
		private var xmlLoader:URLLoader;		// Will read pattern and model information from XML file
		
		private var patternNames:Array;			// Put the names of the patterns in here
		private var patternFiles:Array;			// Stores each of the PATTERN_FILE_X names
		private var codeWidths:Array;			// Stores the widths for all the codes
		private var codeResolutions:Array;		// The number of bits in each pattern
		private var codePercentages:Array;		// The percent of each marker taken up by pattern
		
		// Objects to draw
		private var plane:Plane;				//Flat plane of the recognised pattern
		private var shapes:Array;				//Shapes to be drawn
		
		// Stuff for checking if the match is consistent
		private var modelLocked:Boolean;		// Will be set if 5 frames of the same model seen consecutively
		private var matchedIDs:Array;			// Will store a list of identified models
		private var noSquare:int;				// The number of frames in a row with no square detected
		private var showModel:int;				// The model to show
		
		// Stuff for loading video
		private var myConnections:Array;
		private var myStreams:Array;
		private var myVideos:Array;
		private var mySources:Array;
		
		// Preloader
		private var loadingSprite:LoadingSpriteDisplay;
	
		/***************\
		* Constructor	*
		\***************/
		public function WebDemo() {
			addEventListener(Event.ADDED_TO_STAGE,drawAssets);
		}
	
		
		/*******************\
		* Protected methods	*
		\*******************/
		protected function drawAssets(e:Event):void{
			
			addEventListener(Event.ADDED_TO_STAGE,drawAssets);
			
			loadingSprite = new LoadingSpriteDisplay();
			loadingSprite.addEventListener(Event.ENTER_FRAME,animateLoader);
			addChild(loadingSprite);
			loadingSprite.x = (loadingSprite.stage.stageWidth /2);
			loadingSprite.y = (loadingSprite.stage.stageHeight /2);
			
			
			// Get the base URL
			try{
				var flashVars:Object = LoaderInfo(this.root.loaderInfo).parameters;
				baseURL = (flashVars.baseURL) ? String(flashVars.baseURL) : '';
				patternsLocation = (flashVars.patternsLocation) ? String(flashVars.patternsLocation) : 'Unknown XML!';
			} catch (error:Error){
				trace('Caught error');
				baseURL = '';
			}
			
			// Initialise all of the pattern arrays etc. The values will be parsed from XML
			patternNames = new Array();
			patternFiles = new Array();
			codeWidths = new Array();
			codeResolutions = new Array();
			codePercentages = new Array();
			
			shapes = new Array();
			
			// Load video streams
			mySources = new Array(	baseURL+'Videos/Butterfly.f4v',
								  	baseURL+'Videos/Lake.f4v',
									baseURL+'Videos/Bear.f4v'		);
			myConnections = new Array();
			myStreams = new Array();
			myVideos = new Array();
			for (var i:int = 0; i < mySources.length; i++){
				loadMyVideo(mySources[i]);
			}
			
			
			// Prefill the matchedIDs array with non values
			matchedIDs = new Array(-1,-1,-1,-1,-1);
			modelLocked = false;
			noSquare = 0;
			showModel = -1;
			
			// Move models on key press
			stage.addEventListener(KeyboardEvent.KEY_DOWN, keyListener);
			
			// Read in pattern display information from XML file
			getXMLInfo(baseURL+patternsLocation);
		}
		
		
		override protected function _onEnterFrame(e:Event = null):void {
			
			// Want some way of checking that the identification is consistent before showing the model
			
			this._capture.bitmapData.draw(this._video);
			
			/**************
			* What I'm going to do differently here is separate the iteration over models from iteration over
			*  identified squares. I think these do not need to be done together
			***************/
			
			/****************
			* To reduce false matches, we'll take a rolling average of frames to make a decision
			* Once 5 frames of the same model are seen, it will be locked in
			* Once 5 frames of no square are seen, the model will be unlocked and a new model can be set later
			* If any square is seen, the locked model is shown in that position. Don't even bother looking at pattern until squares are lost
			*****************/
			
			// Special for multi - run this part for each marker
			var activeModel:int = -1;			// This will hold the index of the model to display
			
			var confidentMatchIndeces:Array = new Array();	// This will store any confident matches
			// Do the detection first. Store the number of squares found in squaresFound
			var squaresFound:int = this._detector.detectMarkerLite(this._raster, 80);
			//trace('Number of squares found: '+squaresFound);
			if (squaresFound){
				// Now iterate over the squares that were found. Is this what is returned from detectMarkerLite()?
				for (var i:int = 0; i < squaresFound; i++){
					// Use reduced threshold to make finding anything easier
					if (this._detector.getConfidence(i) > 0.2) {
						confidentMatchIndeces.push({theIndex: i, confidence: this._detector.getConfidence(i)});
					} 
				}
			}
			
			
			// Chose the best square to display
			if (confidentMatchIndeces.length > 0){
				// Sort by confidence 
				if (confidentMatchIndeces.length > 1){
					confidentMatchIndeces = confidentMatchIndeces.sortOn('confidence',Array.DESCENDING); 
				}
				// Pull out index of most confident
				var mostConfident:Number = confidentMatchIndeces[0].theIndex;
				// Get transform for most confident match
				this._detector.getTransmationMatrix(mostConfident,this._resultMat);
				this._baseNode.setTransformMatrix(this._resultMat);
				activeModel = this._detector.getARCodeIndex(mostConfident);
				
				// We found squares so reset count
				noSquare = 0;
			} else {
				noSquare++;
			}
			
			// Now that we have the model, update the recent matches array to make a decision about what to show
			matchedIDs.push(activeModel);
			matchedIDs.shift();
			
			
			// If the model is not locked in, see if it should be
			if (!modelLocked){
				modelLocked = shouldLock();
				// Only set the showModel if we *just* locked the model
				if (modelLocked){
					showModel = activeModel;
				}
			} else {
				modelLocked = shouldUnlock();
			}
			
			// Now decide whether or not to show something
			// If there was a square show what's locked. If it's not locked don't show
			if ((noSquare == 0) && (modelLocked)){
				showTheModel();
			} else if (noSquare > 5){
				this._baseNode.visible = false;
			}
			
			// Finally render the scene
			this._renderer.render();
			
		}
		
		
		/*******************\
		* Private functions	*
		\*******************/
		private function animateLoader(e:Event):void{
			loadingSprite.inner.rotation-=10;
			loadingSprite.outer.rotation+=10;
		}
		
		private function showTheModel():void{
			if (showModel > -1){
				// Turn all models off - this is something I could speed up by loading in the appropriate model
				//  when a new pattern is identified. That way there wouldn't be several to iterate over
				for (var i:int = 0; i < this._patternList.length; i++){
					// Turn only the chosen model on and everything else off
					if (i != showModel){
						this.modelList[i].visible = false;
					} else {
						this.modelList[i].visible = true;
					}
				}
				this._baseNode.visible = true;
			} else {
				this._baseNode.visible = false;
			}
		}
		
		private function shouldLock():Boolean{
			// No point running if anything in there is not a model
			if (matchedIDs[0] != -1){
				var allSame:Boolean = true;
				for (var i:int = 1; i < matchedIDs.length; i++){
					if (matchedIDs[i] != matchedIDs[0]){
						allSame = false;
						break;
					}
				}
				// If they were all the same we can lock that model
				return(allSame);
			} else {
				return(false);
			}
		}
		
		private function shouldUnlock():Boolean{
			// true means the lock is true
			var allSame:Boolean = false;
			for (var i:int = 0; i < matchedIDs.length; i++){
				if (matchedIDs[i] != -1){
					allSame = true;
					break;
				}
			}
			return(allSame);
		}
		
		private function _onInit(e:Event):void {
			this.removeEventListener(Event.INIT, this._onInit);
			
			var light:PointLight3D = new PointLight3D();
			light.x = 1000;
			light.y = 1000;
			light.z = -1000;
			
			// Set up materials
			var blueMaterial:ColorMaterial = new ColorMaterial(0x0000FF);
			var yellowMaterial:ColorMaterial = new ColorMaterial(0xFFFF00);
			yellowMaterial.doubleSided = true;
			//VideoStreamMaterial(video:Video, stream:NetStream, precise:Boolean = false, transparent:Boolean = false)
			var videoMaterial1:VideoStreamMaterial = new VideoStreamMaterial(myVideos[0], myStreams[0]);
			videoMaterial1.doubleSided = true;
			var videoMaterial2:VideoStreamMaterial = new VideoStreamMaterial(myVideos[1], myStreams[1]);
			var videoMaterial3:VideoStreamMaterial = new VideoStreamMaterial(myVideos[2], myStreams[2]);
			// Materials list for cube
			var videoCubeMaterials:MaterialsList = new MaterialsList();
			videoCubeMaterials.addMaterial( videoMaterial1, "front" ); 
			videoCubeMaterials.addMaterial( videoMaterial1, "back" ); 
			videoCubeMaterials.addMaterial( videoMaterial2, "left" ); 
			videoCubeMaterials.addMaterial( videoMaterial2, "right" ); 
			videoCubeMaterials.addMaterial( videoMaterial3, "top" ); 
			videoCubeMaterials.addMaterial( videoMaterial3, "bottom" );
			// For torus
			var torusMaterialsList:MaterialsList = new MaterialsList();
			torusMaterialsList.addMaterial(blueMaterial,"initialShadingGroup");
			// For clock
			var bitmapFileMaterial:BitmapFileMaterial = new BitmapFileMaterial(baseURL+"Bitmaps/clockFace.jpg");
			bitmapFileMaterial.doubleSided = true;
			var colorMaterial1:ColorMaterial = new ColorMaterial(0xD3C8AD);
			colorMaterial1.doubleSided = true;
			var colorMaterial2:ColorMaterial = new ColorMaterial(0xB8A67C);
			colorMaterial2.doubleSided = true;
			var colorMaterial3:ColorMaterial = new ColorMaterial(0x000000);
			colorMaterial3.doubleSided = true;
			var materialsList:MaterialsList = new MaterialsList(); 
			materialsList.addMaterial( bitmapFileMaterial, "SurfaceMaterial06" ); 
			materialsList.addMaterial( colorMaterial1, "color1" ); 
			materialsList.addMaterial( colorMaterial2, "color2" ); 
			materialsList.addMaterial( colorMaterial2, "color3" ); 
			materialsList.addMaterial( colorMaterial1, "color4" ); 
			materialsList.addMaterial( colorMaterial1, "color5" ); 
			materialsList.addMaterial( colorMaterial2, "color6" ); 
			materialsList.addMaterial( colorMaterial2, "color7" ); 
			materialsList.addMaterial( colorMaterial3, "hourArm" ); 
			materialsList.addMaterial( colorMaterial3, "minuteArm" ); 
			// For dancing cylinders
			var cylinderMaterialList:MaterialsList = new MaterialsList();
			var comp:CompositeMaterial = new CompositeMaterial();
			var wire:WireframeMaterial = new WireframeMaterial(0x999999);
			comp.addMaterial(blueMaterial);
			comp.addMaterial(wire);
			cylinderMaterialList.addMaterial(comp, "all");
			
			
			// The models
			modelList = new Array();
			
			modelList[0] = new Plane(yellowMaterial, 80, 80);
			
			
			modelList[1] = new Cube(new MaterialsList({all:blueMaterial}), 40, 40, 40);
			modelList[1].z += 20;
			
			modelList[2] = new Cube(new MaterialsList({all:yellowMaterial}), 40, 40, 40);
			modelList[2].z += 20;
			
			modelList[3] = new Plane(videoMaterial1, 80, 80);
			
			modelList[4] = new Cube(videoCubeMaterials, 40, 40, 40);
			modelList[4].z += 20;
			
			modelList[5] = new Collada(baseURL+"Models/torus1.dae", torusMaterialsList, 0.1);
			
			if (this._patternList.length > 6){
				modelList[6] = new Collada(baseURL+"Models/clock_altered.dae", materialsList, 0.01);
				modelList[6].rotationX +=90;
				modelList[6].rotationZ -=90;
				
				modelList[7] = new DAE(true,'Cylinders',true);	// autoplay, name, loop
				modelList[7].rotationY += 90;
				modelList[7].scale = 1;
				modelList[7].addEventListener(FileLoadEvent.ANIMATIONS_COMPLETE, daeLoadComplete);
				modelList[7].load(baseURL+"Models/CylinderTest-4.DAE",cylinderMaterialList);
			} else {
				modelsToScene();
			}
		}
		
		private function daeLoadComplete(e:FileLoadEvent):void{
			modelList[7].removeEventListener(FileLoadEvent.ANIMATIONS_COMPLETE, modelsToScene);
			modelsToScene();
		}
		
		private function modelsToScene():void{
			// Also remove the preloader
			loadingSprite.removeEventListener(Event.ENTER_FRAME, animateLoader);
			removeChild(loadingSprite);
			loadingSprite = null;
			
			// Add the models to the scene
			for (var i:int = 0; i < modelList.length; i++){
				this._baseNode.addChild(modelList[i]);
			}
			this._baseNode.visible = false;
		}
		
		private function getXMLInfo(filename:String):void{
			// Use the existing loader to get the file
			xmlLoader = new URLLoader();
			xmlLoader.dataFormat = URLLoaderDataFormat.TEXT;
			xmlLoader.addEventListener(Event.COMPLETE,this.parseXMLInfo);
			xmlLoader.addEventListener(IOErrorEvent.IO_ERROR, this.dispatchEvent);
			xmlLoader.addEventListener(SecurityErrorEvent.SECURITY_ERROR, this.dispatchEvent);
			xmlLoader.load(new URLRequest(filename));
		}
		
		private function parseXMLInfo(e:Event){
			xmlLoader.removeEventListener(Event.COMPLETE,this.parseXMLInfo);
			
			// Parse the file and assign models and patterns
			var xmlData:XML = XML(xmlLoader.data);
			
			var patternFolder:String = xmlData.@pattern_folder;
			for each (var card:XML in xmlData.Card){
				// Get the pattern information for each card
				patternNames.push(card.Pattern.Name);
				codeWidths.push(card.Pattern.Width);
				codeResolutions.push(card.Pattern.Resolution);
				codePercentages.push(card.Pattern.Percentage);
				// Put together the full pattern file name
				patternFiles.push(patternFolder + card.Pattern.Name + '_' + card.Pattern.Resolution + '.pat');
				
				
			}
			
			this.addEventListener(Event.INIT,this._onInit);			// Moved this line from the constructor.
			this.init(CAMERA_FILE, patternFiles, codeWidths, codeResolutions, codePercentages);
		}
		
		
		private function loadMyVideo(file:String):void{
			trace('WebDemo: loadMyVideo(): Loading '+file);
			
			//Set up Net Connection
			var myConnection:NetConnection= new NetConnection();
			
			//Not on the media server
			myConnection.connect(null);		// null is a trick to allow local content
			
			var myStream:NetStream = new NetStream(myConnection);
			//Set buffer time
			myStream.bufferTime = 2;
			//Set up My Stream for client
			myStream.client = new Object();
			
			//Instantiate the video
			var myVideo:Video = new Video(320, 240);
			
			myStream.play(file);
			//Attach to local client side video
			myVideo.attachNetStream(myStream);
			
			//Want to repeat any movies that have completed 
			myStream.addEventListener(NetStatusEvent.NET_STATUS, repeatMovie);
			// myStream.client.onPlayStatus = repeatMovie; // Alternative to above
			
			// Mute the stream
			var audioTransform:SoundTransform = new SoundTransform();
			audioTransform.volume = 0;
			myStream.soundTransform = audioTransform;
			
			//Store this video
			myConnections.push(myConnection);
			myStreams.push(myStream);
			myVideos.push(myVideo);
		}
		
		private function repeatMovie(e:NetStatusEvent){
			//e.target is the netstream that dispatched the event
			if (e.info.code == 'NetStream.Play.Stop'){
				// Find out which source we need to reload
				var sourceIndex:int;
				for (sourceIndex = 0; sourceIndex < mySources.length; sourceIndex++){
					if (e.target == myStreams[sourceIndex]){
						break;
					}
				}
				e.target.play(mySources[sourceIndex]);	//Need to tell it what to play
			}
		}
		
		private function keyListener(key:KeyboardEvent){
			switch(key.keyCode){
				case	Keyboard.UP		: 	modelList[2].z += 5;		modelList[5].rotationZ += 5;	break;
				case	Keyboard.DOWN	:	modelList[2].z -= 5;		modelList[5].rotationZ -= 5;	break;
				case	Keyboard.LEFT	:	modelList[2].x += 5;		modelList[5].rotationX += 5;	break;
				case	Keyboard.RIGHT	:	modelList[2].x -= 5;		modelList[5].rotationX -= 5;	break;
			}
		}
		
		
		
	}
	
}