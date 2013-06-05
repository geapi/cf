require "spec_helper"

describe CFManifests do
  let(:inputs_hash) { {} }
  let(:given_hash) { {} }
  let(:global_hash) { {} }
  let(:inputs) { Mothership::Inputs.new(nil, nil, inputs_hash, given_hash, global_hash) }

  let(:cmd) do
    manifest = CF::App::Push.new(nil, inputs)
    manifest.extend CFManifests
    manifest.stub(:client) { client }
    manifest
  end

  let(:target_base) { "some-cloud.com" }

  let(:foo) { build(:app, :name => "foo") }
  let(:bar) { build(:app, :name => "bar") }
  let(:baz) { build(:app, :name => "baz") }
  let(:xxx) { build(:app, :name => "xxx") }
  let(:yyy) { build(:app, :name => "yyy") }

  let(:client) do
    build(:client).tap { |client| client.stub(:apps => [foo, bar, baz, xxx, yyy]) }
  end

  let(:manifest_file) { "/abc/manifest.yml" }

  before do
    cmd.stub(:target_base) { target_base }

    cmd.stub(:manifest) { manifest }
    cmd.stub(:manifest_file) { manifest_file }
  end

  describe "#find_apps" do
    subject { cmd.find_apps(nil) }

    context "when there is no manifest file" do
      before { cmd.stub(:manifest).and_return(nil) }
      it { should eq [] }
    end
  end

  describe "#create_manifest_for" do
    let(:app) do
      build :app,
        :memory => 2048,
        :total_instances => 2,
        :command => "ruby main.rb",
        :buildpack => "git://example.com/foo.git",
        :routes => [
          build(:route,
            :host => "some-app-name",
            :domain => build(:domain, :name => target_base))
        ],
        :service_bindings => [
          build(
            :service_binding,
            :service_instance =>
              build(
                :service_instance,
                :name => "service-1",
                :service_plan =>
                  build(
                    :service_plan,
                    :name => "P200",
                    :service => build(:service))))
        ]
    end

    subject { cmd.create_manifest_for(app, "some-path") }

    its(["name"]) { should eq app.name }
    its(["memory"]) { should eq "2G" }
    its(["instances"]) { should eq 2 }
    its(["path"]) { should eq "some-path" }
    its(["url"]) { should eq "some-app-name.${target-base}" }
    its(["command"]) { should eq "ruby main.rb" }
    its(["buildpack"]) { should eq "git://example.com/foo.git" }

    it "contains the service information" do
      expect(subject["services"]).to be_a Hash

      services = subject["services"]
      app.service_bindings.each do |b|
        service = b.service_instance

        expect(services).to include service.name

        info = services[service.name]

        plan = service.service_plan
        offering = plan.service

        { "plan" => plan.name,
          "label" => offering.label,
          "provider" => offering.provider,
          "version" => offering.version
        }.each do |attr, val|
          expect(info).to include attr
          expect(info[attr]).to eq val
        end
      end
    end

    context "with only minimum configuration" do
      let(:app) {
        build :app,
          :memory => 2048,
          :total_instances => 2,
          :routes => [],
          :service_bindings => []
      }

      its(["url"]) { should eq "none" }
      it { should_not include "command" }
      it { should_not include "services" }
    end
  end

  describe "#setup_services" do
    let(:service_bindings) { [] }
    let(:app) { build :app, :service_bindings => service_bindings }

    before do
      dont_allow_ask(anything, anything)
    end

    context "when services are defined in the manifest" do
      let(:info) do
        {:services => {"service-1" => {:label => "mysql", :plan => "100"}}}
      end

      let(:service_1) { build(:service_instance, :name => "service-1") }
      let(:plan_100) { build :service_plan, :name => "100" }

      let(:mysql) do
        build(
          :service,
          :label => "mysql",
          :provider => "core",
          :service_plans => [plan_100])
      end

      let(:service_instances) { [] }

      let(:client) do
        build(:client).tap { |client| client.stub(:services => [mysql], :service_instances => service_instances) }
      end

      context "and the services exist" do
        let(:service_instances) { [service_1] }

        context "and are already bound" do
          let(:service_bindings) { [build(:service_binding, :service_instance => service_1)] }

          it "does neither create nor bind the service again" do
            cmd.should_not_receive(:invoke).with(:create_service, anything)
            cmd.should_not_receive(:invoke).with(:bind_service, anything)
            cmd.send(:setup_services, app, info)
          end
        end

        context "but are not bound" do
          it "does not create the services" do
            cmd.should_not_receive(:invoke).with(:create_service, anything)
            cmd.stub(:invoke).with(:bind_service, anything)
            cmd.send(:setup_services, app, info)
          end

          it "binds the service" do
            cmd.should_receive(:invoke).with(:bind_service, :app => app, :service => service_1)
            cmd.send(:setup_services, app, info)
          end
        end
      end

      context "and the services do not exist" do
        it "creates the services" do
          cmd.should_receive(:invoke).with(:create_service, :app => app,
            :name => service_1.name, :offering => mysql, :plan => plan_100)
          cmd.should_not_receive(:invoke).with(:bind_service, anything)
          cmd.send(:setup_services, app, info)
        end
      end
    end

    context "when there are no services defined" do
      let(:info) { {} }

      it "does not ask anything" do
        cmd.send(:setup_services, app, info)
      end
    end
  end

  describe "#apps_in_manifest" do
    let(:foo_hash) { { :name => "foo", :path => "/abc/foo" } }
    let(:bar_hash) { { :name => "bar", :path => "/abc/bar" } }
    let(:baz_hash) { { :name => "baz", :path => "/abc/baz" } }

    let(:manifest) { { :applications => [foo_hash, bar_hash, baz_hash] } }

    subject { cmd.apps_in_manifest(inputs) }

    context "when no apps are passed" do
      let(:given_hash) { {} }

      its(:first) { should eq [] }
      its(:last) { should eq [] }
    end

    context "when app names are passed" do
      context "and all of them are in the manifest" do
        let(:given_hash) { { :apps => ["foo", "bar"] } }

        its(:first) { should eq [foo_hash, bar_hash] }
        its(:last) { should eq [] }
      end

      context "and one of them is in the manifest" do
        let(:given_hash) { { :apps => ["foo", "xxx"] } }

        its(:first) { should eq [foo_hash] }
        its(:last) { should eq ["xxx"] }
      end

      context "and none of them are in the manifest" do
        let(:given_hash) { { :apps => ["xxx", "yyy"] } }

        its(:first) { should eq [] }
        its(:last) { should eq ["xxx", "yyy"] }
      end
    end

    context "when apps are passed as paths" do
      context "and the paths are in the manifest" do
        let(:given_hash) { { :apps => ["/abc/foo"] } }

        its(:first) { should eq [foo_hash] }
        its(:last) { should eq [] }
      end

      context "and any path is not in the manifest" do
        let(:given_hash) { { :apps => ["/abc/xxx"] } }

        it "fails with a manifest-specific method (i.e. path not in manifest)" do
          expect { subject }.to raise_error(CF::UserError, /Path .+ is not present in manifest/)
        end
      end
    end
  end

  describe "#all_apps" do
    let(:applications) do
      [
        {:name => "foo", :path => "/abc"},
        {:name => "bar", :path => "/abc"},
        {:name => "baz", :path => "/abc/baz"}
      ]
    end

    let(:manifest) do
      { :applications => applications }
    end

    subject { cmd.all_apps }

    it "returns all of the apps described in the manifest, as hashes" do
      expect(subject).to eq applications
    end
  end

  describe "#current_apps" do
    let(:manifest) do
      {:applications => [
        {:name => "foo", :path => "/abc"},
        {:name => "bar", :path => "/abc"},
        {:name => "baz", :path => "/abc/baz"}
      ]}
    end

    subject { cmd.current_apps }

    it "returns the applications with the cwd as their path" do
      Dir.stub(:pwd) { "/abc" }
      expect(subject).to eq [{ :name => "foo", :path => "/abc"}, { :name => "bar", :path => "/abc" }]
    end
  end
end
