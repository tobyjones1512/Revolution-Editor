import SwiftUI

var clicks = 0
var toggled = 0

struct Counter: View {
    @State private var taps = 0
    var title: String
    var body: some View {
        VStack(spacing: 6) {
            Text(title).font(.headline)
            Text("Taps: \(taps)")
            Button("Tap") {
                taps += 1
                hostValue("taps", taps)
            }
        }
        .padding()
        .background(Color.blue.opacity(0.35))
        .cornerRadius(12)
    }
}

struct Modifiers: View {
    @State private var changes = 0
    @State private var level = 1
    var body: some View {
        VStack {
            Text("Styled").bold().italic().underline().strikethrough().kerning(1).textCase(.uppercase)
            Text("Shadow").padding().background(Color.gray).clipShape(Capsule()).shadow(color: .black, radius: 4, x: 2, y: 3)
            Text("Round").padding().background(Color.green).clipShape(RoundedRectangle(cornerRadius: 10)).overlay(Color.white.opacity(0.2))
            Text("Placed").position(x: 120, y: 60)
            Text("Hold").onLongPressGesture(minimumDuration: 0.3) { changes += 100 }
            Text("Watch").onChange(of: level) { oldValue, newValue in changes += newValue - oldValue }
            Text("Single").onChange(of: level) { newValue in changes += newValue }
            Text("Task").task { changes += 1 }.onDisappear { changes = 0 }
        }
        .navigationTitle("Title")
        .environment(\.colorScheme, .dark)
        .keyboardType(.numberPad)
        .hoverEffect(.lift)
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { changes += 1 }
        .toolbar { Button("x") { changes += 1 } }
        .sheet(isPresented: .constant(false)) { Text("sheet") }
        .alert("Hi", isPresented: .constant(false)) { Button("OK") { } }
        .ignoresSafeArea()
        .containerBackground(.black, for: .navigation)
        .onExitCommand { changes += 1 }
        .menuBarExtraStyle(.window)
        .statusBar(hidden: true)
        .defersSystemGestures(on: .bottom)
        .digitalCrownRotation($level)
        .ignoresSafeArea(.all, edges: .top)
    }
}

struct Badge: View {
    var label: String
    var tint: Color
    var body: some View {
        Text(label)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(tint)
            .cornerRadius(8)
    }
}

struct ContentView: View {
    @State private var count = 0
    @State private var on = true
    @State private var level = 0.5
    let items = ["Apple", "Banana"]

    var header: some View {
        Text("Hello, Wii!")
            .font(.largeTitle)
            .foregroundColor(.yellow)
    }

    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 10) {
                header
                HStack(spacing: 16) {
                    Button("-") { count -= 1; clicks -= 1 }
                    Text("\(count)").font(.title)
                    Button("+") { count += 1; clicks += 1 }
                }
                Toggle("Sound", isOn: $on).frame(width: 260)
                Slider(value: $level, in: 0...1).frame(width: 260)
                ForEach(items, id: \.self) { item in
                    Text(item)
                }
                Counter(title: "Counter")
                if count > 999 { Modifiers() }
                if on {
                    Badge(label: "ON", tint: .green)
                } else {
                    Badge(label: "OFF", tint: .red)
                }
            }
            .padding(20)
        }
    }
}

@main struct DemoApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

func appOnFrame() {
    hostValue("clicks", clicks)
}
