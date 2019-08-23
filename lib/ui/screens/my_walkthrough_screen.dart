import 'dart:async';
import 'package:secure_upload/data/utils.dart' as utils;
import 'package:secure_upload/data/global.dart' as globals;
import 'package:secure_upload/ui/screens/my_onboard_screen.dart';
import 'package:secure_upload/ui/widgets/pager_indicator.dart';
import 'package:secure_upload/ui/widgets/page_dragger.dart';
import 'package:secure_upload/ui/widgets/page_reveal.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';


class MyWalkthroughScreen extends StatefulWidget {
  final SharedPreferences prefs;

  MyWalkthroughScreen({this.prefs});

  _MyWalkthroughScreenState createState() => new _MyWalkthroughScreenState();
}

class _MyWalkthroughScreenState extends State<MyWalkthroughScreen> with TickerProviderStateMixin {
  StreamController<SlideUpdate> slideUpdateStream;
  AnimatedPageDragger animatedPageDragger;

  int activeIndex = 0;
  int nextPageIndex = 0;
  SlideDirection slideDirection = SlideDirection.none;
  double slidePercent = 0.0;

  _MyWalkthroughScreenState() {
    slideUpdateStream = new StreamController<SlideUpdate>();
    ;

    slideUpdateStream.stream.listen((SlideUpdate event) {
      setState(() {
        if (event.updateType == UpdateType.dragging) {
          slideDirection = event.direction;
          slidePercent = event.slidePercent;

          if (slideDirection == SlideDirection.leftToRight) {
            nextPageIndex = activeIndex - 1;
          } else if (slideDirection == SlideDirection.rightToLeft) {
            nextPageIndex = activeIndex + 1;
          } else {
            nextPageIndex = activeIndex;
          }
        } else if (event.updateType == UpdateType.doneDragging) {
          if (slidePercent > 0.5) {
            animatedPageDragger = new AnimatedPageDragger(
              slideDirection: slideDirection,
              transitionGoal: TransitionGoal.open,
              slidePercent: slidePercent,
              slideUpdateStream: slideUpdateStream,
              vSync: this,
            );
          } else {
            animatedPageDragger = new AnimatedPageDragger(
              slideDirection: slideDirection,
              transitionGoal: TransitionGoal.close,
              slidePercent: slidePercent,
              slideUpdateStream: slideUpdateStream,
              vSync: this,
            );

            nextPageIndex = activeIndex;
          }

          animatedPageDragger.run();
        } else if (event.updateType == UpdateType.animating) {
          slideDirection = event.direction;
          slidePercent = event.slidePercent;
        } else if (event.updateType == UpdateType.doneAnimating) {
          activeIndex = nextPageIndex;

          slideDirection = SlideDirection.none;
          slidePercent = 0.0;

          animatedPageDragger.dispose();
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    globals.maxHeight = utils.screenHeight(context);
    globals.maxWidth = utils.screenWidth(context);

    return new Scaffold(
      body: new Stack(
        children: [
          new Page(
            viewModel: pages[activeIndex],
          ),
          new PageReveal(
            revealPercent: slidePercent,
            child: new Page(
              viewModel: pages[nextPageIndex],

              iconPercentVisible: slidePercent*0.5,
              textPercentVisible: slidePercent*0.75,
              titlePercentVisible: slidePercent,
            ),
          ),
          new PagerIndicator(
            viewModel: new PagerIndicatorViewModel(
              pages,
              activeIndex,
              slideDirection,
              slidePercent,
            ),
          ),
          new PageDragger(
            canDragLeftToRight: activeIndex > 0,
            canDragRightToLeft: activeIndex < pages.length - 1,
            slideUpdateStream: this.slideUpdateStream,
          ),
        ],
      ),
    );
  }
}
